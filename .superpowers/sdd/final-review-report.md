# Final Branch Review Report — feat/role-personas

## Fix 1: emitted script paths

### Change
Replaced every literal `./scripts/orca-` with `.orca/orchestration/scripts/orca-` in five files using:
```
for f in scripts/orca-bootstrap-roles.sh scripts/orca-dispatch-role.sh scripts/orca-fallback-on-limit.sh templates/roles.yaml templates/handles.example.json; do
  perl -0pi -e 's{\./scripts/orca-}{.orca/orchestration/scripts/orca-}g' "$f"
done
```

Locations changed:
- `scripts/orca-bootstrap-roles.sh`: `"script": "./scripts/orca-fallback-on-limit.sh"` in Python heredoc + final `Limit failover:` echo
- `scripts/orca-dispatch-role.sh`: `Missing $HANDLES_FILE — run ./scripts/orca-bootstrap-roles.sh first` error string
- `scripts/orca-fallback-on-limit.sh`: `"script": "./scripts/orca-fallback-on-limit.sh"` in Python heredoc
- `templates/roles.yaml`: step 4 text in `limit_failover.policy` AND `script:` key
- `templates/handles.example.json`: `"script"` value

`install-to-project.sh` intentionally NOT touched (its `OLD_SCRIPTS_DIR` cleanup logic references the legacy location).

### Test evidence
```
$ grep -rn '\./scripts/orca-' scripts/orca-*.sh templates/roles.yaml templates/handles.example.json
(no output — PASS)
```

Fresh install check:
```
$ grep "script" .../fresh-install-test/.orca/orchestration/handles.example.json
    "script": ".orca/orchestration/scripts/orca-fallback-on-limit.sh"

$ grep "scripts/orca-" .../fresh-install-test/.orca/orchestration/roles.yaml
    4. Script: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec "..."
  script: .orca/orchestration/scripts/orca-fallback-on-limit.sh
```

---

## Fix 2: migrate_roles in_roles guard

### Change
Added `in_roles` boolean to the `migrate_roles` Python heredoc in `scripts/install-to-project.sh`.

In **both** the prescan loop and the main loop:
- `ROLES_HEADER = re.compile(r'^roles:\s*$')` — detects the top-level `roles:` key
- `is_toplevel_key(line)` — detects non-roles top-level keys via `re.match(r'^[A-Za-z_]', line)`
- When `ROLES_HEADER` matches: `in_roles = True`, `cur = None`
- When another top-level key matches: `in_roles = False`, `cur = None`
- `role_of()` called only when `in_roles` is True
- `persona: |` replacement block guarded with `in_roles`
- coordinator `model:` injection guarded with `in_roles`

### Test evidence

**FIX 2 regression test** (customblocks outside roles: untouched):
```
$ # Fixture: roles: { architect: {persona: |...} } + customblocks: { executor: {persona: | CUSTOM_TOPLEVEL_MARKER} }
$ ./scripts/install-to-project.sh --project-root "$SCRATCH" --migrate-roles
  migrated roles: architect
$ # Result: architect → persona_file: personas/architect.md
$ #         customblocks.executor.persona still has CUSTOM_TOPLEVEL_MARKER — PASS
```

**Task 7 Step 1 original test (8 assertions)**:
```
$ bash -c '... 8 assertion script ...'
OK: --migrate-roles converts legacy personas idempotently
```

**Custom role under roles: preserved**:
```
$ # myrole (not in REPL) under roles: → persona: | CUSTOM_INROLES_MARKER kept inline — PASS
OK: custom role under roles: still preserves inline persona
```

**Syntax checks**:
```
$ bash -n scripts/orca-bootstrap-roles.sh && OK
$ bash -n scripts/orca-dispatch-role.sh && OK
$ bash -n scripts/orca-fallback-on-limit.sh && OK
$ bash -n scripts/install-to-project.sh && OK
```

**check-personas.sh**:
```
$ ./scripts/check-personas.sh
OK: all persona files valid
```
