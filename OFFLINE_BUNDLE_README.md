# Offline Bundle Quick Start

This package is built for Linux x86_64 and includes a bundled AWS CLI in `vendor/aws-cli/`.

## 1) Extract

```bash
tar -xzf io-perf-offline-*.tar.gz
cd io-perf-offline-*
```

## 2) Minimal setup

- Required for all modes: `bash`, `python3`
- Filesystem mode: `fio`
- HDFS mode: `hdfs` or `hadoop` CLI (expected on server)
- S3 mode: AWS credentials (IAM role or env vars), and region

Example (if not using EC2 role):

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-southeast-1"
```

## 3) Run single entrypoint

```bash
chmod +x universal_io_test.sh
./universal_io_test.sh
```

Then follow prompts:
1. Select Storage Type: Filesystem / HDFS / Object (S3)
2. Select IO profile flow for that storage

## Notes

- Bundled AWS CLI is auto-detected by scripts; `source env.sh` is optional.
- Output CSV files are compatible with `io_compare.html`.
