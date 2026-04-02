#!/usr/bin/env sh
set -eu

SCRIPT_NAME=$(basename "$0")
DEFAULT_DATASET_NAME="dummy-dataset"
DEFAULT_ACCOUNT_MODE="double"

print_help() {
    cat <<EOF
Usage:
  sh $SCRIPT_NAME <TOTAL_SIZE> <CHUNK_SIZE> [DATASET_NAME] [single|double]
  ./$SCRIPT_NAME <TOTAL_SIZE> <CHUNK_SIZE> [DATASET_NAME] [single|double]

Arguments:
  TOTAL_SIZE    Target space usage you want to occupy
  CHUNK_SIZE    Target releasable chunk size
  DATASET_NAME  Optional output directory name in the current working directory
                Default: $DEFAULT_DATASET_NAME
  single|double Optional accounting mode
                Default: $DEFAULT_ACCOUNT_MODE

Accounting mode:
  double  Assume the filesystem/accounting shows about 2x usage in 'du'.
          The script will create files at half the requested size so that the
          observed disk usage is closer to the requested TOTAL_SIZE/CHUNK_SIZE.

  single  Normal 1x behavior. The script will create files at the exact
          requested size.

Behavior:
  - The dataset is created under the current working directory
  - Default output directory: ./$DEFAULT_DATASET_NAME
  - Files are named: part_0000.bin, part_0001.bin, ...
  - If TOTAL_SIZE is not divisible by CHUNK_SIZE:
      part_0000.bin = remainder chunk
      all following files = standard chunk size
  - In 'double' mode, file sizes are scaled down by factor 2 before creation

Examples:
  1) sh $SCRIPT_NAME 10G 1G
     Meaning:
       Target observed usage = 10G
       Target releasable chunk = 1G
       Output directory = ./$DEFAULT_DATASET_NAME
       Mode = double
     Result:
       The script creates files of about 512M each so that your filesystem
       may report about 1G usage per file.

  2) sh $SCRIPT_NAME 10G 1G my-dataset
     Meaning:
       Same as above, but output directory is ./my-dataset

  3) sh $SCRIPT_NAME 10G 1G single
     Meaning:
       Output directory = ./$DEFAULT_DATASET_NAME
       Mode = single
     Result:
       The script creates real 1G files.

  4) sh $SCRIPT_NAME 10G 1G my-dataset single
     Meaning:
       Output directory = ./my-dataset
       Mode = single

Notes:
  - Supported size strings include: 512M, 10G, 100G, 1T
  - This script uses fallocate, not dd
EOF
}

if [ "$#" -eq 1 ]; then
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
    esac
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    echo "Error: invalid arguments."
    echo
    print_help
    exit 1
fi

TOTAL_SIZE_STR=$1
CHUNK_SIZE_STR=$2
DATASET_NAME=$DEFAULT_DATASET_NAME
ACCOUNT_MODE=$DEFAULT_ACCOUNT_MODE

if [ "$#" -eq 3 ]; then
    case "$3" in
        single|double)
            ACCOUNT_MODE=$3
            ;;
        *)
            DATASET_NAME=$3
            ;;
    esac
fi

if [ "$#" -eq 4 ]; then
    DATASET_NAME=$3
    ACCOUNT_MODE=$4
fi

case "$ACCOUNT_MODE" in
    single)
        ACCOUNT_FACTOR=1
        ;;
    double)
        ACCOUNT_FACTOR=2
        ;;
    *)
        echo "Error: accounting mode must be 'single' or 'double'."
        exit 1
        ;;
esac

DATA_DIR="$PWD/$DATASET_NAME"

if ! command -v fallocate >/dev/null 2>&1; then
    echo "Error: fallocate command not found."
    exit 1
fi

if ! command -v numfmt >/dev/null 2>&1; then
    echo "Error: numfmt command not found."
    exit 1
fi

REQUEST_TOTAL_BYTES=$(numfmt --from=iec "$TOTAL_SIZE_STR")
REQUEST_CHUNK_BYTES=$(numfmt --from=iec "$CHUNK_SIZE_STR")

if [ "$REQUEST_TOTAL_BYTES" -le 0 ]; then
    echo "Error: TOTAL_SIZE must be greater than 0."
    exit 1
fi

if [ "$REQUEST_CHUNK_BYTES" -le 0 ]; then
    echo "Error: CHUNK_SIZE must be greater than 0."
    exit 1
fi

# Convert requested observed usage into real file size to create.
REAL_TOTAL_BYTES=$(((REQUEST_TOTAL_BYTES + ACCOUNT_FACTOR - 1) / ACCOUNT_FACTOR))
REAL_CHUNK_BYTES=$(((REQUEST_CHUNK_BYTES + ACCOUNT_FACTOR - 1) / ACCOUNT_FACTOR))

if [ "$REAL_TOTAL_BYTES" -le 0 ] || [ "$REAL_CHUNK_BYTES" -le 0 ]; then
    echo "Error: computed real file size is invalid."
    exit 1
fi

FULL_COUNT=$((REAL_TOTAL_BYTES / REAL_CHUNK_BYTES))
REMAINDER=$((REAL_TOTAL_BYTES % REAL_CHUNK_BYTES))

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

human_size() {
    numfmt --to=iec-i --suffix=B "$1"
}

create_file() {
    index=$1
    size_bytes=$2
    filename=$(printf "part_%04d.bin" "$index")

    echo "Creating ${filename} ($(human_size "$size_bytes")) ..."
    fallocate -l "$size_bytes" "$filename"
}

echo "Working directory      : $OLDPWD"
echo "Target directory       : $DATA_DIR"
echo "Requested total size   : $TOTAL_SIZE_STR ($(human_size "$REQUEST_TOTAL_BYTES"))"
echo "Requested chunk size   : $CHUNK_SIZE_STR ($(human_size "$REQUEST_CHUNK_BYTES"))"
echo "Accounting mode        : $ACCOUNT_MODE"
echo "Accounting factor      : ${ACCOUNT_FACTOR}x"
echo "Real total file size   : $(human_size "$REAL_TOTAL_BYTES")"
echo "Real chunk file size   : $(human_size "$REAL_CHUNK_BYTES")"
echo "Full chunks            : $FULL_COUNT"
echo "Remainder              : $(human_size "$REMAINDER")"
echo

if [ -n "$(find . -maxdepth 1 -type f -name 'part_*.bin' -print -quit)" ]; then
    echo "Warning: existing part_*.bin files were found in $DATA_DIR"
    echo "New files may overwrite old files with the same names."
    echo
fi

index=0

# Create the remainder file first so the smallest file has the smallest index.
if [ "$REMAINDER" -gt 0 ]; then
    create_file "$index" "$REMAINDER"
    index=$((index + 1))
fi

# Create all standard chunk files.
i=0
while [ "$i" -lt "$FULL_COUNT" ]; do
    create_file "$index" "$REAL_CHUNK_BYTES"
    index=$((index + 1))
    i=$((i + 1))
done

echo
echo "Done."
echo "Created dataset files in: $DATA_DIR"
du -sh "$DATA_DIR"
du -sh --apparent-size "$DATA_DIR"
ls -lh "$DATA_DIR"
