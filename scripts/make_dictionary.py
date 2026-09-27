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

数据源：
  - https://github.com/skywind3000/ECDICT （MIT License）
  - 词根词缀：ECDICT 仓库 wordroot.txt（MIT）
  - 英英同义词：Moby Thesaurus II（Grady Ward，公有领域）
用法：
  精简版（默认）：python3 scripts/make_dictionary.py <ecdict.csv> \
              [--wordroot wordroot.txt] [--thesaurus mthesaur.txt]
  完整版：      python3 scripts/make_dictionary.py <ecdict.csv> --preset full \
              [--wordroot wordroot.txt] [--thesaurus mthesaur.txt]
  仅增强：  python3 scripts/make_dictionary.py --enrich <dictionary.sqlite> \
              --wordroot wordroot.txt --thesaurus mthesaur.txt

收录规则（默认 preset=core，目标：单词 + 短语 + 专业术语的离线词典）：
  1. 核心：当代语料库词频 frq 或 BNC 词频 bnc 排名前 15 万；
     或柯林斯星级 collins>=1；或牛津 3000 核心词 oxford=1
  2. 注释长尾：无排名但自带音标、且为纯字母单词（长度<=25）；
     或缩写——全大写 2-8 字母、或释义带 abbr. 标记（带中文释义）
  3. 词形家族：exchange 以 "0:<原形>" 指向已收录词的变体
     （went/gave 等本身无词频排名的词形）
  4. 短语与专业术语：2 到 5 个单词、带中文释义的多词词条
     （含 [计]/[医]/[化]/[经] 等领域术语，全量收录）

preset=full 在 core 基础上放宽（收录无音标但有释义的单词、短语 2-8 词）；
注意：生成体积同时取决于源 CSV 规模（仓库内置精简版源自较小源文件）。

增强表（--wordroot / --thesaurus 可选输入）：
  roots(word_roots) —— 词根词缀库与词条直接反查索引
  thesaurus —— 英英同义词（每词截取前 12 条）

生成表结构：
  dictionary(word 主键 COLLATE NOCASE, phonetic, translation, definition,
             exchange, tag, collins, oxford, bnc, frq)
  roots(key 主键, meaning, class, origin, examples)
  word_roots(word 主键 COLLATE NOCASE, root_keys)
  thesaurus(word 主键 COLLATE NOCASE, synonyms)
  meta(key, value) — 数据来源、条目数、生成参数等元信息
"""

import argparse
import csv
import datetime
import json
import os
import re
import sqlite3
import sys

# ECDICT 的 word 字段实际存在的字符范围（含连字符词、所有格如 'em）
SINGLE_WORD = re.compile(r"^[A-Za-z][A-Za-z'\-]*$")
ACRONYM = re.compile(r"^[A-Z]{2,8}$")
MAX_WORD_LEN = 25
FREQ_TOP = {"core": 150_000, "full": 300_000}
PHRASE_MIN_WORDS = 2
PHRASE_MAX_WORDS = {"core": 5, "full": 8}

COLUMNS = ["word", "phonetic", "translation", "definition",
           "exchange", "tag", "collins", "oxford", "bnc", "frq"]

MAX_SYNONYMS = 12
MAX_ROOT_EXAMPLES = 8


def enrich(db, wordroot_path, thesaurus_path):
    """写入词根词缀库与英英同义词表（幂等：先 DROP 再建）。"""
    db.execute("DROP TABLE IF EXISTS roots")
    db.execute("DROP TABLE IF EXISTS word_roots")
    db.execute("DROP TABLE IF EXISTS thesaurus")

    if wordroot_path:
        roots = json.load(open(wordroot_path, encoding="utf-8"))
        db.execute(
            "CREATE TABLE roots ("
            "key TEXT PRIMARY KEY, "
            "meaning TEXT NOT NULL DEFAULT '', "
            "class TEXT NOT NULL DEFAULT '', "
            "origin TEXT NOT NULL DEFAULT '', "
            "examples TEXT NOT NULL DEFAULT '')")
        db.execute(
            "CREATE TABLE word_roots ("
            "word TEXT PRIMARY KEY COLLATE NOCASE, "
            "root_keys TEXT NOT NULL)")
        word2keys = {}
        for key, info in roots.items():
            examples = ", ".join((info.get("example") or [])[:MAX_ROOT_EXAMPLES])
            db.execute(
                "INSERT OR IGNORE INTO roots (key, meaning, class, origin, examples) "
                "VALUES (?,?,?,?,?)",
                (key, info.get("meaning") or "", info.get("class") or "",
                 info.get("origin") or "", examples))
            for word in info.get("example") or []:
                word2keys.setdefault(word.lower(), []).append(key)
        db.executemany(
            "INSERT OR IGNORE INTO word_roots (word, root_keys) VALUES (?,?)",
            [(w, ",".join(ks)) for w, ks in word2keys.items()])
        db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('wordroot', ?)",
            (str(len(roots)),))
        print(f"词根/词缀 {len(roots)} 条，直接反查词 {len(word2keys)} 个")

    if thesaurus_path:
        db.execute(
            "CREATE TABLE thesaurus ("
            "word TEXT PRIMARY KEY COLLATE NOCASE, "
            "synonyms TEXT NOT NULL)")
        count = 0
        with open(thesaurus_path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split(",")
                if len(parts) < 2:
                    continue
                word = parts[0].strip().lower()
                synonyms = [p.strip() for p in parts[1:MAX_SYNONYMS + 1] if p.strip()]
                if word and synonyms:
                    db.execute(
                        "INSERT OR IGNORE INTO thesaurus (word, synonyms) VALUES (?,?)",
                        (word, ",".join(synonyms)))
                    count += 1
        db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('thesaurus', ?)",
            (str(count),))
        print(f"同义词 {count} 条")
    db.commit()


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


def select_entries(entries, preset="core"):
    """按收录规则筛选，返回 {word_lower: row}。"""
    freq_top = FREQ_TOP[preset]
    phrase_max = PHRASE_MAX_WORDS[preset]
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
        translation = (row.get("translation") or "").strip()
        definition = (row.get("definition") or "").strip()
        if (0 < frq <= freq_top or 0 < bnc <= freq_top
                or collins >= 1 or oxford == 1):
            keep(word, row)
        elif ((preset == "full" and (phonetic or translation)
                or preset == "core" and phonetic)
                and SINGLE_WORD.match(word) and len(word) <= MAX_WORD_LEN):
            keep(word, row)
        elif (translation and (ACRONYM.match(word)
                              or translation.lower().startswith("abbr")
                              or definition.lower().startswith("abbr"))):
            keep(word, row)
        elif (PHRASE_MIN_WORDS <= len(word.split()) <= phrase_max
                and translation
                and (preset == "core"
                     or not translation.startswith("[网络]")
                     or frq > 0 or bnc > 0)):
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


def build_db(selected, out_path, preset="core"):
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
                ("freq_top", str(FREQ_TOP[preset])),
                ("phrase_max_words", str(PHRASE_MAX_WORDS[preset])),
                ("preset", preset),
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
    parser = argparse.ArgumentParser(description="生成/增强 Voca 内嵌词典")
    parser.add_argument("ecdict_csv", nargs="?", help="ECDICT 的 ecdict.csv 路径")
    parser.add_argument("--enrich", metavar="DB",
                        help="仅增强已有词典库（词根/同义词表），不重算词条")
    parser.add_argument("--preset", choices=["core", "full"], default="core",
                        help="收录规则预设：core＝精简（默认），full＝完整（体积约 4 倍）")
    parser.add_argument("--wordroot", help="ECDICT wordroot.txt 路径（词根词缀）")
    parser.add_argument("--thesaurus", help="Moby Thesaurus II mthesaur.txt 路径")
    parser.add_argument("-o", "--output",
                        default=os.path.join(os.path.dirname(__file__), "..",
                                             "Sources", "Voca", "Resources",
                                             "dictionary.sqlite"),
                        help="输出路径（默认 Sources/Voca/Resources/dictionary.sqlite）")
    args = parser.parse_args()

    if args.enrich:
        if not os.path.exists(args.enrich):
            sys.exit(f"词典库不存在：{args.enrich}")
        db = sqlite3.connect(args.enrich)
        try:
            enrich(db, args.wordroot, args.thesaurus)
            db.execute("VACUUM")
            db.commit()
        finally:
            db.close()
        size = os.path.getsize(args.enrich) / 1048576
        print(f"增强完成 {args.enrich}（{size:.1f} MB）")
        return

    if not args.ecdict_csv:
        sys.exit("请提供 ecdict.csv，或使用 --enrich 增强已有词典库")

    entries = load_entries(args.ecdict_csv)
    print(f"读取 {len(entries)} 条原始词条（preset={args.preset}）")
    selected = select_entries(entries, preset=args.preset)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    build_db(selected, args.output, preset=args.preset)
    if args.wordroot or args.thesaurus:
        db = sqlite3.connect(args.output)
        try:
            enrich(db, args.wordroot, args.thesaurus)
        finally:
            db.close()


if __name__ == "__main__":
    sys.exit(main())
