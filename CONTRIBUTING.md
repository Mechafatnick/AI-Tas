# Contributing

Please keep the repository buildable without fetching source from another
repository.

Before submitting a change:

```sh
python3 tools/check_self_contained.py
make -j2 test
```

For FPGA changes, build with Quartus Prime Lite 24.1 and include the relevant
Quartus report summaries when investigating timing/resource regressions.

Do not add game ROMs to git. ROM validation and assembly should remain in the
MiSTer `.mra` flow or in local-only test fixtures.
