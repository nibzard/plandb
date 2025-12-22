# dev_nvme Baselines

This directory contains performance baselines for the dev_nvme profile.

## Profile Requirements

The dev_nvme profile is automatically detected when:
- CPU cores >= 8
- RAM >= 16 GB
- High-performance storage (ext4/xfs)

## Current Status

The `bench/macro/task_queue_claims` baseline is pending collection on a machine that meets dev_nvme requirements.

To generate dev_nvme baselines:
```bash
# On a machine with 8+ cores and 16GB+ RAM:
./zig-out/bin/bench run --repeats 3 --filter "task_queue" --suite macro --output bench/baselines/dev_nvme/
```

The macrobenchmark implementation is complete and CI baselines are available in `bench/baselines/ci/bench/macro/`.
