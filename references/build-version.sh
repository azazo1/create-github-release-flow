#!/usr/bin/env bash

set -euo pipefail

# 复制到项目 scripts/build-version.sh 后, 通常只需要改 TAG_PREFIX.
# 不要改后面的 tag / dirty 算法.
TAG_PREFIX="v"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

git_output() {
  local output
  if ! output="$(git "$@" 2>/dev/null)"; then
    return 1
  fi
  output="$(printf '%s' "$output" | tr -d '\r')"
  output="${output#"${output%%[![:space:]]*}"}"
  output="${output%"${output##*[![:space:]]}"}"
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output"
}

select_version_tag() {
  local tags="$1"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # 与 describe 的 --match 保持一致: 设了 TAG_PREFIX 时只接受带前缀的 tag,
    # 免得同一个 tag 在 HEAD 上被当成版本号, 不在 HEAD 上却解析失败.
    if [[ -z "$TAG_PREFIX" || "$line" == "$TAG_PREFIX"* ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done <<< "$tags"
  return 1
}

# 包版本可能已经带上 tag 前缀 (调用方直接传了 v0.1.0), 统一剥掉, 避免拼出双前缀.
normalize_package_version() {
  local version="$1"
  if [[ -n "$TAG_PREFIX" && "$version" == "$TAG_PREFIX"* ]]; then
    printf '%s\n' "${version#"$TAG_PREFIX"}"
  else
    printf '%s\n' "$version"
  fi
}

# 取不到版本 tag 时说明具体原因, 区分"仓库确实没有 tag", "有 tag 但没一个匹配 TAG_PREFIX"
# 和"本地没有 tag 对象 (浅克隆或没 fetch tags)"三种情况.
diagnose_missing_tag() {
  local all_tags matched_tags first_tag first_matched
  all_tags="$(git_output tag --list || true)"
  if [[ -n "$TAG_PREFIX" ]]; then
    matched_tags="$(git_output tag --list "${TAG_PREFIX}*" || true)"
  else
    matched_tags="$all_tags"
  fi

  first_tag=""
  if [[ -n "$all_tags" ]]; then
    first_tag="$(printf '%s\n' "$all_tags" | head -n 1)"
  fi
  first_matched=""
  if [[ -n "$matched_tags" ]]; then
    first_matched="$(printf '%s\n' "$matched_tags" | head -n 1)"
  fi

  if [[ -z "$first_matched" && "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
    printf '本地是浅克隆, 取不到远端 tag'
  elif [[ -z "$first_tag" ]]; then
    printf '仓库里没有任何 tag'
  elif [[ -z "$first_matched" ]]; then
    printf '本地 tag 没有一个匹配 TAG_PREFIX=%s (现有第一个 tag 是 %s)' "$TAG_PREFIX" "$first_tag"
  else
    printf '本地有版本 tag (%s), 但 describe 从 HEAD 取不到它' "$first_matched"
  fi
}

# 仓库还没有任何版本 tag 时的兜底基础版本号, 由调用方提供.
# 各语言模块给出该生态的结构化 metadata 读取命令, 在 just dist 或 CI 里先算出包版本,
# 再用 PROJECT_PACKAGE_VERSION 传进来; 不要在本脚本里正则扫清单文件.
read_package_version() {
  local reason
  reason="$(diagnose_missing_tag)"

  if [[ -z "${PROJECT_PACKAGE_VERSION:-}" ]]; then
    echo "${reason}, 且未提供 PROJECT_PACKAGE_VERSION" >&2
    echo "按语言模块给出的结构化命令读出包版本后传给 PROJECT_PACKAGE_VERSION, 或先打一个版本 tag (检查 TAG_PREFIX 前缀, 浅克隆要 fetch tags)" >&2
    return 1
  fi

  echo "警告: ${reason}; 基础版本号改用包版本 $(normalize_package_version "$PROJECT_PACKAGE_VERSION") 加短 hash" >&2
  normalize_package_version "$PROJECT_PACKAGE_VERSION"
}

describe_latest_tag() {
  if [[ -n "$TAG_PREFIX" ]]; then
    git_output describe --tags --abbrev=0 --match "${TAG_PREFIX}*" HEAD
  else
    git_output describe --tags --abbrev=0 HEAD
  fi
}

strip_tag_prefix() {
  local display="$1"
  if [[ -n "$TAG_PREFIX" && "$display" == "$TAG_PREFIX"* ]]; then
    printf '%s\n' "${display#"$TAG_PREFIX"}"
  else
    printf '%s\n' "$display"
  fi
}

exact_tag=""
if tags="$(git_output tag --points-at HEAD)"; then
  exact_tag="$(select_version_tag "$tags" || true)"
fi

if [[ -n "$exact_tag" ]]; then
  tag="$exact_tag"
else
  tag="$(describe_latest_tag || true)"
  if [[ -z "$tag" ]]; then
    tag="${TAG_PREFIX}$(read_package_version)"
  fi
fi

commit="$(git_output rev-parse --short=7 HEAD || true)"
dirty=false
if [[ -n "$commit" ]]; then
  set +e
  git diff-index --quiet HEAD --
  status=$?
  set -e
  if [[ "$status" -eq 1 ]]; then
    dirty=true
  fi
fi

if [[ -z "$commit" ]]; then
  display="$tag"
elif [[ "$dirty" == true ]]; then
  display="${tag}^${commit}"
elif [[ -n "$exact_tag" ]]; then
  display="$tag"
else
  display="${tag}-${commit}"
fi

strip_tag_prefix "$display"
