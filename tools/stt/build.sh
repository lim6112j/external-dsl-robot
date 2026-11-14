#!/usr/bin/env bash
# robotdsl 음성 인식 헬퍼를 빌드한다.
#
# macOS 27 SDK 에서 installTap(onBus:bufferSize:format:block:) 이 deprecated
# 경고를 낸다. 대체 API가 확정되지 않았고 현재 API도 정상 동작하므로 그대로 두며,
# 경고는 빌드를 막지 않는다.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc 를 찾을 수 없습니다. Xcode 명령줄 도구를 설치하세요." >&2
  exit 1
fi

echo "building tools/stt/stt ..."
swiftc -O main.swift -o stt

echo
echo "built: $(pwd)/stt"
echo
echo "권한 프롬프트 없이 가용성만 확인하려면:"
echo "  ./stt --probe"
