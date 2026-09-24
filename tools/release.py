import sys
import re
import subprocess
from pathlib import Path

def run_cmd(cmd, cwd=None):
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True, cwd=cwd)

def find_paths():
    script_dir = Path(__file__).resolve().parent
    # Possible candidates for _meta.lua depending on invocation or layout
    candidates = [
        script_dir.parent / "plugin" / "beeline.koplugin" / "_meta.lua",
        script_dir.parent / "beeline.koplugin" / "_meta.lua",
        script_dir.parent / "beeline" / "plugin" / "beeline.koplugin" / "_meta.lua",
        Path.cwd() / "plugin" / "beeline.koplugin" / "_meta.lua",
        Path.cwd() / "beeline" / "plugin" / "beeline.koplugin" / "_meta.lua",
    ]
    for c in candidates:
        if c.exists():
            meta_path = c.resolve()
            # Find git repository root by checking parent directories for .git
            for parent in [meta_path.parent.parent.parent, meta_path.parent.parent, meta_path.parent, script_dir.parent]:
                if (parent / ".git").exists():
                    return meta_path, parent.resolve()
            return meta_path, script_dir.parent.resolve()
    return None, None

def main():
    if len(sys.argv) != 2:
        print("Usage: python release.py <new_version>")
        sys.exit(1)

    new_version = sys.argv[1].strip()
    
    meta_path, repo_root = find_paths()
    if not meta_path or not meta_path.exists():
        print("Error: Could not find beeline.koplugin/_meta.lua")
        sys.exit(1)
        
    print(f"Updating version to {new_version} in {meta_path.name}")
    content = meta_path.read_text(encoding="utf-8")
    
    # Find and replace the version string
    new_content, count = re.subn(r'version\s*=\s*"[^"]+"', f'version = "{new_version}"', content)
    
    if count == 0:
        print("Error: Could not find version string in _meta.lua")
        sys.exit(1)
        
    version_changed = (content != new_content)
    
    if version_changed:
        meta_path.write_text(new_content, encoding="utf-8")
        print("Version updated successfully in _meta.lua.")
    else:
        print(f"Version is already set to {new_version} in _meta.lua.")

    # Also update worker/package.json if it exists
    pkg_changed = False
    pkg_path = repo_root / "worker" / "package.json"
    if pkg_path.exists():
        pkg_content = pkg_path.read_text(encoding="utf-8")
        new_pkg_content, pkg_count = re.subn(r'"version"\s*:\s*"[^"]+"', f'"version": "{new_version}"', pkg_content)
        if pkg_count > 0 and pkg_content != new_pkg_content:
            pkg_path.write_text(new_pkg_content, encoding="utf-8")
            pkg_changed = True
            print(f"Version updated successfully in {pkg_path.name}.")
    
    # Git operations
    print("Executing git commands...")
    try:
        if version_changed or pkg_changed:
            files_to_add = []
            if version_changed:
                files_to_add.append(str(meta_path.resolve()))
            if pkg_changed:
                files_to_add.append(str(pkg_path.resolve()))
            run_cmd(["git", "add"] + files_to_add, cwd=repo_root)
            run_cmd(["git", "commit", "-m", f"Release {new_version}"], cwd=repo_root)
            
        # Check if tag already exists locally
        tag_check = subprocess.run(["git", "tag", "-l", new_version], capture_output=True, text=True, cwd=repo_root)
        tag_exists = new_version in tag_check.stdout.splitlines()
        if not tag_exists:
            run_cmd(["git", "tag", new_version], cwd=repo_root)
        else:
            print(f"Tag {new_version} already exists locally. Skipping local tag creation.")
            
        # Push commit and/or tag in a single git push command to avoid entering passphrase twice
        push_cmd = ["git", "push", "origin"]
        if version_changed or pkg_changed:
            push_cmd.extend(["HEAD", new_version])
        else:
            push_cmd.append(new_version)
            
        run_cmd(push_cmd, cwd=repo_root)
        print(f"\n✅ Release {new_version} completed and pushed successfully!")
    except subprocess.CalledProcessError as e:
        print(f"Error during git operations: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
