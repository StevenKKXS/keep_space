#!/usr/bin/env sh
set -eu

SCRIPT_NAME=$(basename "$0")
DEFAULT_DATASET_NAME="dummy-idataset"
PROGRESS_EVERY=10000

print_help() {
    cat <<EOF_HELP
Usage:
  sh $SCRIPT_NAME <TOTAL_INODES> <CHUNK_INODES> [DATASET_NAME]
  ./$SCRIPT_NAME <TOTAL_INODES> <CHUNK_INODES> [DATASET_NAME]

Arguments:
  TOTAL_INODES  Target inode usage you want to occupy
  CHUNK_INODES  Target releasable inode chunk size
  DATASET_NAME  Optional output directory name in the current working directory
                Default: $DEFAULT_DATASET_NAME

Behavior:
  - The dataset is created under the current working directory
  - Default output directory: ./$DEFAULT_DATASET_NAME
  - Chunk directories are named: chunk_0000, chunk_0001, ...
  - Files are named: inode_000000.dat, inode_000001.dat, ...
  - Each chunk consumes inode units by:
      1 directory inode + (N-1) file inodes = N total inode units
  - If TOTAL_INODES is not divisible by CHUNK_INODES:
      chunk_0000 = remainder chunk
      all following chunks = standard chunk size

Examples:
  1) sh $SCRIPT_NAME 1M 100K
  2) sh $SCRIPT_NAME 500K 50K my-idataset

Notes:
  - Supported count strings include: 1000, 10K, 1M, 2G (SI units)
  - For large inode targets, creation can take significant time
EOF_HELP
}

if [ "$#" -eq 1 ]; then
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
    esac
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Error: invalid arguments."
    echo
    print_help
    exit 1
fi

TOTAL_INODES_STR=$1
CHUNK_INODES_STR=$2
DATASET_NAME=$DEFAULT_DATASET_NAME

if [ "$#" -eq 3 ]; then
    DATASET_NAME=$3
fi

if ! command -v numfmt >/dev/null 2>&1; then
    echo "Error: numfmt command not found."
    exit 1
fi

if ! command -v df >/dev/null 2>&1; then
    echo "Error: df command not found."
    exit 1
fi

if ! REQUEST_TOTAL_INODES=$(numfmt --from=si "$TOTAL_INODES_STR" 2>/dev/null); then
    echo "Error: invalid TOTAL_INODES: $TOTAL_INODES_STR"
    exit 1
fi

if ! REQUEST_CHUNK_INODES=$(numfmt --from=si "$CHUNK_INODES_STR" 2>/dev/null); then
    echo "Error: invalid CHUNK_INODES: $CHUNK_INODES_STR"
    exit 1
fi

if [ "$REQUEST_TOTAL_INODES" -le 0 ]; then
    echo "Error: TOTAL_INODES must be greater than 0."
    exit 1
fi

if [ "$REQUEST_CHUNK_INODES" -le 0 ]; then
    echo "Error: CHUNK_INODES must be greater than 0."
    exit 1
fi

REAL_TOTAL_INODES=$REQUEST_TOTAL_INODES
REAL_CHUNK_INODES=$REQUEST_CHUNK_INODES

if [ "$REAL_TOTAL_INODES" -le 0 ] || [ "$REAL_CHUNK_INODES" -le 0 ]; then
    echo "Error: computed real inode target is invalid."
    exit 1
fi

FULL_COUNT=$((REAL_TOTAL_INODES / REAL_CHUNK_INODES))
REMAINDER=$((REAL_TOTAL_INODES % REAL_CHUNK_INODES))
TOTAL_CHUNKS=$FULL_COUNT
if [ "$REMAINDER" -gt 0 ]; then
    TOTAL_CHUNKS=$((TOTAL_CHUNKS + 1))
fi

# Dataset root directory itself usually consumes 1 inode as fixed overhead.
REQUIRED_WITH_OVERHEAD=$((REAL_TOTAL_INODES + 1))
IFREE_BEFORE=$(df -Pi "$PWD" | awk 'NR==2 {print $4}')

if [ -z "$IFREE_BEFORE" ]; then
    echo "Error: failed to detect available inodes from df -Pi."
    exit 1
fi

if [ "$IFREE_BEFORE" -lt "$REQUIRED_WITH_OVERHEAD" ]; then
    echo "Error: not enough free inodes in current filesystem."
    echo "Available inodes : $IFREE_BEFORE"
    echo "Required (est.)  : $REQUIRED_WITH_OVERHEAD"
    exit 1
fi

DATA_DIR="$PWD/$DATASET_NAME"

human_count() {
    numfmt --to=si "$1"
}

create_chunk() {
    index=$1
    inode_units=$2
    dir_name=$(printf "chunk_%04d" "$index")
    file_count=0

    if [ "$inode_units" -gt 1 ]; then
        file_count=$((inode_units - 1))
    fi

    echo "Creating ${dir_name} (inode units=$(human_count "$inode_units"), files=$(human_count "$file_count")) ..."

    if [ -e "$dir_name" ]; then
        echo "Warning: ${dir_name} already exists. Existing entries may affect exact inode usage."
    fi

    mkdir -p "$dir_name"

    file_index=0
    while [ "$file_index" -lt "$file_count" ]; do
        file_name=$(printf "%s/inode_%06d.dat" "$dir_name" "$file_index")
        : > "$file_name"
        file_index=$((file_index + 1))

        if [ "$file_index" -gt 0 ] && [ $((file_index % PROGRESS_EVERY)) -eq 0 ]; then
            echo "  ${dir_name}: created $(human_count "$file_index") files ..."
        fi
    done
}

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

if [ -n "$(find . -maxdepth 1 -type d -name 'chunk_[0-9][0-9][0-9][0-9]' -print -quit)" ]; then
    echo "Warning: existing chunk_* directories were found in $DATA_DIR"
    echo "New chunks may overwrite existing files with the same names."
    echo
fi

echo "Working directory           : $OLDPWD"
echo "Target directory            : $DATA_DIR"
echo "Requested total inodes      : $TOTAL_INODES_STR ($(human_count "$REQUEST_TOTAL_INODES"))"
echo "Requested chunk inodes      : $CHUNK_INODES_STR ($(human_count "$REQUEST_CHUNK_INODES"))"
echo "Total inode target          : $(human_count "$REAL_TOTAL_INODES")"
echo "Chunk inode target          : $(human_count "$REAL_CHUNK_INODES")"
echo "Full chunks                 : $FULL_COUNT"
echo "Remainder                   : $(human_count "$REMAINDER")"
echo "Total chunks to create      : $TOTAL_CHUNKS"
echo

index=0

# Create the remainder chunk first so smallest chunk usually has smallest index.
if [ "$REMAINDER" -gt 0 ]; then
    create_chunk "$index" "$REMAINDER"
    index=$((index + 1))
fi

full_chunk_index=0
while [ "$full_chunk_index" -lt "$FULL_COUNT" ]; do
    create_chunk "$index" "$REAL_CHUNK_INODES"
    index=$((index + 1))
    full_chunk_index=$((full_chunk_index + 1))
done

sync

IFREE_AFTER=$(df -Pi "$DATA_DIR" | awk 'NR==2 {print $4}')
OBSERVED_CONSUMED="N/A"
if [ -n "$IFREE_AFTER" ]; then
    OBSERVED_CONSUMED=$((IFREE_BEFORE - IFREE_AFTER))
fi

CHUNK_DIR_COUNT=$(find "$DATA_DIR" -maxdepth 1 -type d -name 'chunk_[0-9][0-9][0-9][0-9]' | wc -l | tr -d ' ')
FILE_COUNT=$(find "$DATA_DIR" -type f -name 'inode_*.dat' | wc -l | tr -d ' ')

echo
echo "Done."
echo "Created inode dataset in: $DATA_DIR"
echo "Chunk directories         : $(human_count "$CHUNK_DIR_COUNT")"
echo "Data files                : $(human_count "$FILE_COUNT")"
echo "Target inode units        : $(human_count "$REAL_TOTAL_INODES")"
echo "Observed inode delta      : $OBSERVED_CONSUMED"
echo
echo "Current inode usage:"
df -i "$DATA_DIR"
echo
ls -lh "$DATA_DIR" | head -n 20
