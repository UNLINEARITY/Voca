#!/usr/bin/env python3
# Voca — a macOS menu bar app for saving selected text globally.
# Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
"""从 ECDICT 原始 CSV 生成 Voca 内嵌只读词典 dictionary.sqlite。

数据源：https://github.com/skywind3000/ECDICT （MIT License）
用法：python3 scripts/make_dictionary.py <ecdict.csv> [-o 输出路径]

收录规则（目标：约 20MB 覆盖日常 + 考试 + 带注释的难词）：
  1. 核心：当代语料库词频 frq 或 BNC 词频 bnc 排名前 15 万；
     或柯林斯星级 collins>=1；或牛津 3000 核心词 oxford=1
  2. 注释长尾：无排名但自带音标、且为纯字母单词（长度<=25）
  3. 词形家族：exchange 以 "0:<原形>" 指向已收录词的变体
     （went/gave 等本身无词频排名的词形）

生成表结构：
  dictionary(word 主键 COLLATE NOCASE, phonetic, translation, definition,
             exchange, tag, collins, oxford, bnc, frq)
  meta(key, value) — 数据来源、条目数、生成参数等元信息
"""

import argparse
import csv
import datetime
import os
import re
import sqlite3
import sys

# ECDICT 的 word 字段实际存在的字符范围（含连字符词、所有格如 'em）
SINGLE_WORD = re.compile(r"^[A-Za-z][A-Za-z'\-]*$")
MAX_WORD_LEN = 25
FREQ_TOP = 150_000

COLUMNS = ["word", "phonetic", "translation", "definition",
           "exchange", "tag", "collins", "oxford", "bnc", "frq"]


def to_int(value):
    try:
        return int(str(value).strip() or 0)
    except (TypeError, ValueError):
        return 0


def load_entries(csv_path):
    """读取 CSV，返回 [(word, row_dict), ...]，键为原样 word。"""
    entries = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            word = (row.get("word") or "").strip()
            if word:
                entries.append((word, row))
    return entries


def select_entries(entries):
    """按收录规则筛选，返回 {word_lower: row}。"""
    selected = {}

    def keep(word, row):
        selected[word.lower()] = row

    # 规则 1+2：核心词 + 带音标的注释长尾
    for word, row in entries:
        frq = to_int(row.get("frq"))
        bnc = to_int(row.get("bnc"))
        collins = to_int(row.get("collins"))
        oxford = to_int(row.get("oxford"))
        phonetic = (row.get("phonetic") or "").strip()
        if (0 < frq <= FREQ_TOP or 0 < bnc <= FREQ_TOP
                or collins >= 1 or oxford == 1):
            keep(word, row)
        elif (phonetic and SINGLE_WORD.match(word) and len(word) <= MAX_WORD_LEN):
            keep(word, row)

    # 规则 3：词形家族（exchange "0:<原形>" 指向已收录词）
    family_added = 0
    for word, row in entries:
        if word.lower() in selected:
            continue
        exchange = row.get("exchange") or ""
        for part in exchange.split("/"):
            if part.startswith("0:") and part[2:].lower() in selected:
                keep(word, row)
                family_added += 1
                break

    print(f"核心+注释长尾: {len(selected) - family_added}，词形家族补充: {family_added}，"
          f"合计: {len(selected)}")
    return selected


def build_db(selected, out_path):
    if os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
    try:
        db.execute(
            "CREATE TABLE dictionary ("
            "word TEXT PRIMARY KEY COLLATE NOCASE, "
            + ", ".join(f"{c} TEXT NOT NULL DEFAULT ''" for c in COLUMNS[1:6])
            + ", collins INTEGER NOT NULL DEFAULT 0"
            ", oxford INTEGER NOT NULL DEFAULT 0"
            ", bnc INTEGER NOT NULL DEFAULT 0"
            ", frq INTEGER NOT NULL DEFAULT 0)")
        placeholders = ", ".join("?" * len(COLUMNS))
        db.executemany(
            f"INSERT OR IGNORE INTO dictionary ({', '.join(COLUMNS)}) VALUES ({placeholders})",
            [(w, *[(r.get(c) or "").strip() if c in ("phonetic", "translation",
                                                     "definition", "exchange", "tag")
                   else to_int(r.get(c))
                   for c in COLUMNS[1:]]) for w, r in selected.items()])
        db.execute(
            "CREATE TABLE meta ("
            "key TEXT PRIMARY KEY, "
            "value TEXT NOT NULL)")
        db.executemany(
            "INSERT INTO meta(key, value) VALUES (?, ?)",
            [
                ("source", "ECDICT"),
                ("source_url", "https://github.com/skywind3000/ECDICT"),
                ("source_license", "MIT"),
                ("entries", str(len(selected))),
                ("freq_top", str(FREQ_TOP)),
                ("generated", datetime.date.today().isoformat()),
            ])
        db.commit()
        db.execute("VACUUM")
        db.commit()
    finally:
        db.close()
    size = os.path.getsize(out_path) / 1048576
    print(f"生成 {out_path}（{size:.1f} MB，{len(selected)} 条）")


def main():
    parser = argparse.ArgumentParser(description="生成 Voca 内嵌词典")
    parser.add_argument("ecdict_csv", help="ECDICT 的 ecdict.csv 路径")
    parser.add_argument("-o", "--output",
                        default=os.path.join(os.path.dirname(__file__), "..",
                                             "Sources", "Voca", "Resources",
                                             "dictionary.sqlite"),
                        help="输出路径（默认 Sources/Voca/Resources/dictionary.sqlite）")
    args = parser.parse_args()

    entries = load_entries(args.ecdict_csv)
    print(f"读取 {len(entries)} 条原始词条")
    selected = select_entries(entries)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    build_db(selected, args.output)


if __name__ == "__main__":
    sys.exit(main())
