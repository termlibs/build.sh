#!/usr/bin/env bash
# Compile a bash script into a single file with all imports inlined
shopt -s extglob

if [ -z "$1" ]; then
  echo "Usage: $0 <file>"
  exit 1
fi

# keep track of what's been injected already
declare -a sourced

# zsh handling
if  [ -n "$ZSH_VERSION" ]; then
  emulate -L bash
fi

# `_validate_file`
# ----------------
# Run various validations with the given path, intended to be used with
# a command line argument/option for common checks with nice output.
# ```
# Usage: _validate_file <path> [flags]
# Returns: None
# Exit codes:
#  0: No checks failed
#  1: No input file (-z)
# 10: File does not exist (-e)
# 11: File is not readable (-r)
# 12: File is not a regular file (-f)
# 13: File is empty (-s)
# 14: File is not writable (-w)
# 15: File is not executable (-x)
# ```
_validate_path() {
  [ -z "$1" ] && return 1

  local file="$1"
  local flags="${2:-er}"
  while true; do
    local flag="${flags:0:1}"
    flags="${flags:1}"
    case "$flag" in
      e)
        [ -e "$file" ] || {
          printf "File does not exist: %s\n" "$file"
          return 10
        }
        ;;
      r)
        [ -r "$file" ] || {
          printf "File is not readable: %s\n" "$file"
          return 11
        }
        ;;
      f)
        [ -f "$file" ] || {
          printf "File is not a regular file: %s\n" "$file"
          return 12
        }
        ;;
      d)
        [ -d "$file" ] || {
          printf "File is not a directory: %s\n" "$file"
          return 12
        }
        ;;
      s)
        [ -s "$file" ] || {
          printf "File is empty: %s\n" "$file"
          return 13
        }
        ;;
      w)
        [ -w "$file" ] || {
          printf "File is not writable: %s\n" "$file"
          return 14
        }
        ;;
      x)
        [ -x "$file" ] || {
          printf "File is not executable: %s\n" "$file"
          return 15
        }
        ;;

      *)
        break
        ;;
    esac
  done
}



# Parse each line of the script and expand any source/imports or other macros
# into the actual content of the file
# Args:
#   $1: The file to compile
#   $2: The line to parse
#   $3: The temp file to write data to
# Returns: None
_handle_script_line() {
  local script_relative_path source_file source_line
  local to_compile="$1"
  local line="$2"
  local temp_file="$3"
  local first_skipped=false
  # handle shebang or blank lines or any other skipables
  if [[ "$line" =~ ^#! ]] || [ -z "$line" ]; then
    return
  fi
  # Handle source/imports
  if [[ "$line" =~ "# shellcheck source=" ]] || [[ "$line" =~ "^#"*"termlibs=" ]]; then
    # throw away next line after checking double checking we are sourcing next
    read -r _next_line
    if ! [[ "$_next_line" =~ ^source ]]; then
      printf "Error: Expected source directive after # shellcheck source= in %s . Skipping import, file may not work\n" "$to_compile" >&2

    fi
    script_relative_path="${line#*source=}"
    source_file="$(realpath "$(dirname "$to_compile")/$script_relative_path")"
    if ! [[ " ${sourced[@]} " =~ " ${source_file} " ]]; then
      sourced+=("$source_file")
      printf "### %5s ### %s\n" "START" "$script_relative_path" >> "$temp_file"
      while IFS='' read -r source_line; do
        _handle_script_line "$source_file" "$source_line" "$temp_file"
      done < "$source_file"
      printf "\n### %5s ### %s\n" "END" "$script_relative_path" >> "$temp_file"
    else
      printf "# Source file %s already included above\n" "${source_file#$PWD/}" >> "$temp_file"
    fi
  else
    printf "%s\n" "$line" >> "$temp_file"
  fi
}

compile_script() {
  local opts
  opts="$(getopt -o "fhs:o:" --long "force,help,target-shell:,output-name:" -n "compile-script" -- "$@")"
  [ "$?" -eq 0 ] || exit 1
  eval set -- "$opts"

  local ARG_OUTPUT_NAME ARG_TARGET_SHELL ARG_FORCE=false
  while true; do
    case "$1" in
    -h | --help)
      printf "Usage: %s <file>\n" "$0"
      printf "Options:\n"
      printf "  -f, --force: Overwrite the compiled file if it exists\n"
      printf "  -o, --output-name: The name of the compiled script. Default is the same as the input script\n"
      printf "  -s  --target-shell: The shell to compile the script to. Default is bash\n"
      printf "  -h, --help: Show this help message\n"
      exit 0
      ;;
    -s | --target-shell)
      ARG_TARGET_SHELL="$2"W
      shift 2
      ;;
    -f | --force)
      ARG_FORCE=true
      shift
      ;;
    -o | --output-name)
      ARG_OUTPUT_NAME="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    esac
  done
  [ "${#}" -gt 1 ] && {
    printf "Error: Too many arguments\n" >&2
    exit 1
  }
  _validate_path "$1"
  if [ -z "$ARG_OUTPUT_NAME" ]; then
    ARG_OUTPUT_NAME="./dist/$(basename "${1%.sh}.sh")"
  else
    ARG_OUTPUT_NAME="./dist/${ARG_OUTPUT_NAME%.sh}.sh"
  fi
  [ -n "$ARG_TARGET_SHELL" ] || ARG_TARGET_SHELL="bash"

  local to_compile="$(realpath "${1}")"
  if _validate_path "${ARG_OUTPUT_NAME}" er 2> /dev/null && ! [ "$ARG_FORCE" = true ]; then
    printf "Error: Compiled file already exists. Use -f to overwrite\n" >&2
    exit 1
  fi

  local temp_file="$(mktemp -t "pub-shell-compile.XXXXXXXXXX")"
  trap 'rm -f "$temp_file"' EXIT

  # start compiling
  printf "#!/usr/bin/env %s\n" "$ARG_TARGET_SHELL" > "$temp_file"
  local line
  while IFS='' read -r line; do
    printf "check line $line\n"
    _handle_script_line "$to_compile" "$line" "$temp_file"
  done < "$to_compile"
  cp "$temp_file" "$ARG_OUTPUT_NAME"
}

compile_script "$@"
