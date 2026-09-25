"""复制到项目 scripts/entry.py, 作为 PyInstaller 的入口脚本.

包内的 __main__.py 通常用相对导入 (由 python -m 执行时成立), 而 PyInstaller 会把入口脚本
当作顶层 __main__ 执行, 这时相对导入必然失败. 所以这里用绝对导入转一次, 只调用 main().

复制后把 PROJECT 换成实际包名.
"""

from PROJECT.__main__ import main

if __name__ == "__main__":
    main()
