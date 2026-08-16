import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
p = r"project.yml"
s = open(p, encoding="utf-8").read()

old = """    resources:
      - ClawTalk/Resources
"""
new = """    resources:
      - path: ClawTalk/Resources
        excludes:
          - SharedSupport
      - path: ClawTalk/Resources/SharedSupport
        type: folder
"""
# the main app target is the first occurrence (ClawTalk app); keyboard has its own resources below
assert s.count(old) >= 1, s.count(old)
s = s.replace(old, new, 1)

assert s.count("CURRENT_PROJECT_VERSION: 15") == 2, s.count("CURRENT_PROJECT_VERSION: 15")
s = s.replace("CURRENT_PROJECT_VERSION: 15", "CURRENT_PROJECT_VERSION: 16")
open(p, "w", encoding="utf-8", newline="").write(s)
print("project.yml fixed, version 16")
