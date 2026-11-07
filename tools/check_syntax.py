#!/usr/bin/env python3
import glob
import sys
import os

try:
    from luaparser import ast
except ImportError:
    ast = None

def check_syntax(directory):
    failed = False
    lua_files = glob.glob(os.path.join(directory, '**', '*.lua'), recursive=True)
    if not lua_files:
        print(f"No .lua files found in {directory}")
        return False

    if ast is None:
        import subprocess
        # Fallback to luac, luajit, or wsl luajit -b if luaparser is not installed
        for f in lua_files:
            passed = False
            # Try luac
            try:
                res = subprocess.run(["luac", "-p", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if res.returncode == 0:
                    passed = True
            except FileNotFoundError:
                pass

            # Try local luajit
            if not passed:
                try:
                    res = subprocess.run(["luajit", "-b", f, os.devnull], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if res.returncode == 0:
                        passed = True
                except FileNotFoundError:
                    pass

            # Try wsl luajit
            if not passed:
                try:
                    # Convert path to WSL path
                    wsl_path = subprocess.check_output(["wsl", "wslpath", "-u", os.path.abspath(f)]).decode().strip()
                    res = subprocess.run(["wsl", "/usr/lib/koreader/luajit", "-b", wsl_path, "/dev/null"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if res.returncode == 0:
                        passed = True
                except Exception:
                    pass

            if not passed:
                print(f"SYNTAX ERROR IN {f}")
                failed = True
        return not failed

    for f in lua_files:
        try:
            with open(f, encoding='utf-8') as file:
                ast.parse(file.read())
        except Exception as e:
            err_msg = str(e)[:200]
            print(f"SYNTAX ERROR IN {f}: {err_msg}")
            failed = True

    return not failed

if __name__ == "__main__":
    target_dir = sys.argv[1] if len(sys.argv) > 1 else "plugin/beeline.koplugin"
    if check_syntax(target_dir):
        print(f"ALL FILES IN {target_dir} PASS SYNTAX CHECK")
        sys.exit(0)
    else:
        sys.exit(1)
