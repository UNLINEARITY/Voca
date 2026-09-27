#!/usr/bin/env python3
# Voca — a macOS menu bar app for saving selected text globally.
# Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
# General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
"""从 scripts/terms.csv 生成运行时术语覆盖库 terms.sqlite。

查词时 DictionaryService 以本库为最高优先级覆盖 ECDICT 的释义，
用于修正计算机/具身智能术语的翻译；更新流程＝编辑 CSV → 重跑本脚本。
"""

import csv
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CSV = os.path.join(HERE, "terms.csv")
DEFAULT_OUT = os.path.join(HERE, "..", "Sources", "Voca", "Resources", "terms.sqlite")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="生成术语覆盖库 terms.sqlite")
    parser.add_argument("csv", nargs="?", default=DEFAULT_CSV, help="terms.csv 路径")
    parser.add_argument("-o", "--output", default=DEFAULT_OUT, help="输出路径")
    args = parser.parse_args()

    rows = []
    with open(args.csv, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            word = (row.get("word") or "").strip()
            translation = (row.get("translation") or "").strip()
            definition = (row.get("definition") or "").strip()
            tag = (row.get("tag") or "").strip()
            if word and translation:
                rows.append((word, translation, definition, tag))
    if not rows:
        sys.exit("terms.csv 无有效行")

    out = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    try:
        db.execute(
            "CREATE TABLE terms ("
            "word TEXT PRIMARY KEY COLLATE NOCASE, "
            "translation TEXT NOT NULL, "
            "definition TEXT NOT NULL DEFAULT '', "
            "tag TEXT NOT NULL DEFAULT '')"
        )
        db.executemany("INSERT OR REPLACE INTO terms VALUES (?, ?, ?, ?)", rows)
        db.commit()
        db.execute("VACUUM")
        db.commit()
    finally:
        db.close()
    size = os.path.getsize(out) / 1024
    print(f"生成 {out}（{size:.1f} KB，{len(rows)} 条术语）")


if __name__ == "__main__":
    main()
