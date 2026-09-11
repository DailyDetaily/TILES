> 2026-09-11 업데이트: 현재 상단 Dock은 파일 **1~500개**의 **정리 추천**과 최대 두 개 기존 폴더로의 **바로 이동**을 지원합니다. 추천 드롭은 드래그 종료 뒤 지속되는 검토 패널을 열고 원본은 그대로 둡니다. 바로 이동은 묶음 전체를 검사한 뒤 기존 폴더로 이동하며 하나의 기록으로 되돌립니다. 폴더 감시는 별도 명시 설정으로 추가됐으며 기본은 꺼짐입니다. 현재 제품 계약은 [프로젝트 정리 PRD](docs/planning/project-organization-prd.md)와 [README](README.md), 최신 검증 결과는 [검증 기록](VERIFICATION.md)을 따릅니다. 아래의 한 파일 제한, 당시 API와 검증 수치는 이전 구현 기록입니다.

# 추천 폴더 오버레이 — 구현 및 검증

2026-09-10. 기존 **자료 정리** 앱의 상단 추천을 **자동 숨김 폴더 Dock**으로 수정했습니다. 실행 앱은 `dist/TILES.app`입니다. 아래 사용 방법과 표시 구조는 위치 일치·중앙 스냅·메뉴바가 반영된 당시 버전 기준입니다.

## 사용 방법과 지원 범위

1. 메뉴바의 **흑백 3×3 퍼즐 아이콘 → 추천 폴더 켜기**, 또는 **03 규칙 → 상단 추천 폴더**를 켭니다. 상태표시줄에는 채운 T자 타일만 표시하고 나머지 네 칸은 투명하게 둡니다. Dock의 앱 아이콘은 빈 칸의 회색 외곽선을 유지합니다. 새 설정과 이전 버전 설정의 초기값은 **끔**입니다.
2. 같은 화면의 **정리 위치 연결…**에서 이동할 기존 폴더를 선택합니다. 끌어온 파일의 원래 위치는 자동으로 기억하므로 원본 폴더를 미리 등록할 필요가 없습니다. 실제 접근 권한이 부족할 때만 **원본 폴더 연결…**을 사용합니다.
3. 평소에는 **탭·아이콘·배경 모두 보이지 않습니다**. 파일 하나를 설정한 Dock 영역으로 끌어오면 폴더 Dock이 나타납니다. 숨김 감지 영역의 위치와 크기는 표시될 Dock 전체 영역과 같습니다. 기본값은 메뉴바/노치 아래 중앙 520×196pt입니다.
4. 반투명 블러 앞면을 가진 폴더와 가운데 정렬한 이름이 가로로 최대 세 개 표시됩니다. 첫 추천은 블루, 다음 추천들은 블랙입니다. 폴더 안에는 실제 파일에서 가져온 최대 세 개의 이미지 썸네일 또는 파일 형식 아이콘을 표시합니다. 안내 문구는 본 영역 상단에 가운데 정렬하며, 기본값·완료·폴더 열기·되돌리기는 공통 배경 없이 개별 버튼만 영역 밖에 표시합니다. 원하는 폴더에 놓으면 검사 후 기존 이동 서비스를 실행합니다. 선택한 폴더만 강조되며 드래그 중 대상 위치는 바뀌지 않습니다.
5. 실제 이동 완료 후 **폴더 열기 / 되돌리기**가 표시됩니다. 결과 안내는 포인터가 밖에 있을 때 자동으로 위로 사라집니다. 앱을 다시 실행한 뒤에도 기존 **02 기록**에서 되돌릴 수 있습니다.
6. 메뉴바 또는 **03 규칙 → 위치·크기 편집…**을 누르면 Dock이 고정됩니다. 빈 곳(상단 여백·폴더 사이·하단 여백)을 잡아 옮기고, 영역 바깥의 곡선 핸들 중 하나를 잡아 크기를 바꿉니다. 이동 중 화면 가로·세로 중앙 가까이 가면 해당 축에 붙고 안내선이 표시됩니다. 크기를 바꾸면 모서리 반경에 맞춰 바깥 핸들의 곡률이 바뀝니다. 핸들은 모서리 윤곽에서 12pt 떨어진 검은색 6pt 선이며 양 끝은 둥근 캡입니다. 선의 길이는 약 30.63pt로 고정됩니다. Dock 외곽선은 표시하지 않습니다. **완료**로 숨기고, **기본값**으로 중앙 520×196pt로 되돌립니다. 기능이 꺼져 있다면 편집 시작 시 켜집니다.
7. 위치와 크기는 기존 `Settings.json`의 optional `folderDockLayout`에 저장됩니다. 편집 상태 자체는 저장하지 않습니다. 옮기거나 크기를 바꾸면 숨김 감지 영역도 **같은 위치·크기**로 따라갑니다.
8. 메뉴바에서 **자료 정리 열기 / 정리 내역 / 추천 폴더 켜기 / 위치·크기 편집 / 폴더 연결 / 자료 정리 종료**를 선택합니다. 주 창을 닫아도 메뉴바와 켜진 오버레이는 유지됩니다. 앱을 완전히 종료하려면 종료 메뉴를 사용합니다.

트리거는 **보이지 않는 저장된 Dock 영역에 들어온 실제 AppKit 드래그**입니다. 일반 포인터 이동·파일 클릭·선택은 Dock을 펼치지 않습니다. 버튼이 눌리지 않은 동안 수신 창은 `ignoresMouseEvents = true`로 일반 입력을 통과시킵니다. 전역 파일 감지, 클립보드 폴링, 이벤트 훅은 없습니다. 헤더·빈 공간·폴더 사이·패널 밖에는 드롭해도 이동하지 않습니다. 편집 중에는 파일 드롭을 수락하지 않습니다.

**반투명 배경:** `NSVisualEffectView(.popover, .behindWindow)`를 사용합니다. macOS의 **시스템 설정 → 손쉬운 사용 → 디스플레이 → 투명도 줄이기**가 켜져 있으면 시스템이 불투명 재질로 표시합니다. 이번 검증 캡처는 시스템의 불투명 대체 재질입니다. 앞선 검증에서 읽은 값은 `true`였습니다. 시스템 설정은 변경하지 않았습니다. `동작 줄이기`가 켜져 있으면 슬라이드 대신 100ms 페이드로 바뀝니다.

첫 버전은 **같은 로컬 볼륨의 일반 파일 한 개**만 처리합니다. 복수 파일, 폴더·패키지, 웹 주소, file promise, 별칭·심볼릭 링크, 미다운로드 클라우드 항목, 비로컬·다른 볼륨은 거절합니다. 기존 일괄 정리 기능의 범위는 그대로입니다. 새 폴더 생성, 파일명 변경, 덮어쓰기, 복사 후 삭제를 추가하지 않았습니다.

## 실제 기존 코드와 재사용 지점

프로젝트는 Swift Package 기반 SwiftUI/AppKit 앱이며 최소 배포 대상은 macOS 14입니다. 기존 `Window("자료 정리", id: "main")`를 유지하고 `MenuBarExtra`를 추가했습니다. 주 창을 닫아도 앱이 유지되며, 메뉴에서 다시 열거나 종료할 수 있습니다. 로그인 실행·자동 정리 감시기는 추가하지 않았습니다.

| 기존 파일 / 심볼 | 재사용 및 최소 변경 |
| --- | --- |
| `App.swift` / `MaterialOrganizerApp`, `AppDelegate` | 기존 주 창, 메뉴바, 명시적 종료 및 표시 프로세스의 시작·정리를 연결 |
| `AppModel.swift` / `SavedSettings`, `remember`, `addFolders`, `chooseDestination` | 기존 JSON 설정과 폴더 선택·보안 범위 북마크 재사용. optional 켜기·Dock 배치 설정, 닫힌 창 다시 열기, 연결 유효성·자원 해제 보강 |
| `Rules.swift`, `Planner.categoryFor` | 기존 이름 분류 정책 그대로 사용. 메서드의 접근 범위만 공개 |
| `Planner.singleFilePlan` | 드롭 종료 후 기존 `ScanPlan` 한 항목을 만드는 어댑터. 원본 보호·참조 검사 우회 없음 |
| `Organizer.execute`, `Organizer.undo` | 실제 이동·검증·내역·Undo를 전부 기존 서비스로 실행 |
| `JournalStore` | 기존 배타 잠금, 원자적 기록, 재실행 복구 그대로 사용 |
| `SafeFileSystem.moveExclusively` | 기존 `renameatx_np(..., RENAME_EXCL)` 재사용. 실제 쓰기 직전에 목적지 부모 디렉터리 identity 검사 추가 |
| `Theme.swift` | 기존 메인 UI 폰트·색상 보존. Dock은 macOS 시스템 글꼴·실제 폴더 아이콘·기본 20pt 비율의 모서리 사용 |
| `HistoryAndRules.swift` | 기존 규칙 화면의 토글·폴더 연결에 위치·크기 편집 및 기본값 버튼 연결 |

다른 이동 엔진, AI 공급자, 새 자동 정리 시스템, 별도 저장 폴더 레지스트리를 만들지 않았습니다. 의존성을 추가하거나 저장소를 초기화하지 않았습니다. 기존 메인 화면·퍼즐 모션·분류 정책은 유지했습니다.

## 표시와 입력 구조

- `FileDragReceiver.swift`: 실제 `NSDraggingDestination` 수신 뷰. `draggingEntered` 이후에만 AppKit pasteboard의 파일 URL·항목 수·소스 operation을 읽습니다.
- `FolderOverlayController.swift`: 숨김·진입·후보·호버·이동·완료·실패·취소·편집 상태, 위치·크기와 폴더 hit-test를 관리합니다.
- `FolderDockResizeHandles.swift`: 편집 전용 투명 여백에 그리는 바깥 곡선 핸들. 곡선 주변만 resize 입력을 받고 기존 버튼·이동 영역은 통과합니다.
- `FolderOverlayView.swift`: 비활성 AppKit 유리 재질 Dock. macOS 폴더 아이콘과 이름을 가로로 배치하고, 추천 근거는 호버 안내, 전체 경로와 근거는 툴팁·접근성 이름으로 제공합니다.
- `FolderDropSession.swift`: 세션 토큰, 최초 후보 고정, 늦은 결과 무시, 동일 시퀀스 중복 실행 방지, 화면 좌표 계산입니다.
- `FolderDockLayout.swift`: 정규화한 위치, 제한한 크기, 메뉴바·노치·음수 원점 대응, 네 모서리 resize, 중앙 스냅, 모서리 둥글기 비율, 그리기와 hit-test가 함께 사용하는 폴더 영역 계산.
- `OrganizerStatusMenu.swift`: 기존 `AppModel`을 공유하는 메뉴바 기능과 단일 주 창 다시 열기. 내부 표시 프로세스에는 메뉴바를 만들지 않습니다.
- `FolderOverlayHost.swift`, `FolderOverlayTransport.swift`: 아래의 표시 프로세스 수명과 제한된 상태 전달, 주 앱의 배치 저장·편집 완료 요청을 담당합니다.

실제 장시간 Finder 호버 테스트에서 일반 앱 프로세스 안의 패널은 포커스를 가져오는 경우가 확인됐습니다. 최종 구현은 **동일한 서명 실행 파일의 내부 표시 모드**를 별도 프로세스로 실행하고, 이 모드에만 공개 `NSApplication`의 `.prohibited` 활성화 정책을 적용합니다. 메인 앱은 기존 활성화·Dock·창 정책을 유지합니다. 새로운 앱 번들·로그인 항목은 없습니다.

표시 모드에는 이동 엔진·설정 저장·폴더 권한 결정권이 없습니다. 상속한 stdin/stdout pipe로만 상태와 요청을 주고받으며 서버·소켓·네트워크 연결은 없습니다. 메인 앱이 세션 nonce, 요청 중복, 현재 연결·설정 revision, 후보 identity를 다시 확인한 뒤 기존 엔진을 호출합니다. 드래그 중에는 원본 폴더 등록 여부로 차단하지 않습니다. 메인 앱은 드롭 종료 후 실제 경로와 접근 권한을 확인하며, 드롭 URL 수신만으로 권한이 있다고 가정하지 않습니다.

기능을 끄면 표시 창, 포인터 타이머, 화면 알림, pipe와 표시 프로세스를 정리합니다. 주 앱 종료·pipe EOF에도 종료합니다. 표시 프로세스가 실패하면 재시도 이동 없이 토글을 끄고 기존 기록을 확인하도록 안내합니다. 이미 수락해 처리 중인 작업은 메인 앱의 기존 busy·기록 정책을 따릅니다.

숨김 창은 표시 콘텐츠·그림자 없이 저장한 Dock 프레임과 같은 투명 수신 영역을 유지합니다. 기본 Dock은 520×196pt이고 편집 범위는 360…920 × 172…340pt입니다. 화면이 더 작으면 화면 안에 맞춥니다. 진입할 때 수신 창을 최종 위치·크기로 즉시 배치한 후 **내용만 220ms ease-out으로 아래로**, 숨길 때 **180ms ease-in으로 위로** 움직입니다. 진입 모션 중에는 드롭을 수락하지 않으며, 이후 폴더 hit-test는 고정됩니다. 모션 도중 새 드래그가 오면 이전 숨김 완료 콜백이 새 상태를 지우지 않도록 세대를 확인합니다. Esc는 Finder가 처리하며 키 이벤트 훅은 없습니다.

빈 영역 드래그와 네 모서리 resize는 편집 모드의 일반 마우스 이벤트로 처리합니다. 이동 중 Dock 중심이 물리 화면 중심에 12pt 이내로 접근하면 해당 축을 맞추고, 22pt를 벗어나면 풀립니다. 가로·세로는 각각 적용되며 비활성·입력 통과 안내선이 잠깐 나타납니다. resize나 파일 드래그에는 중앙 스냅을 적용하지 않습니다. 모서리 반경은 짧은 변 × 20/196이며 바깥 핸들은 같은 곡선 중심에서 반경에 12pt를 더한 호로 그립니다. 선 길이 9.75πpt를 유지하도록 모서리 대각선을 중심으로 호의 각도만 바꿉니다. 화면/메뉴바 가장자리에는 외부 선이 잘리지 않도록 16pt 여백을 확보합니다. 편집 중에만 창을 사방 24pt 확장하고 Dock 콘텐츠를 안쪽에 놓아 외부 핸들 입력을 받습니다. 저장·중앙 스냅·resize의 기준은 여백을 제외한 Dock 프레임입니다. 편집을 마치면 감지 창은 Dock 프레임으로 돌아옵니다. 드래그 시작 프레임을 기준으로 계산하고 반대쪽 모서리는 고정합니다. 가로·세로 위치는 화면 내 사용 가능 구간의 비율, 크기는 AppKit point로 저장합니다. 단순 배치 저장은 폴더 권한·추천 revision을 바꾸지 않습니다. 주 앱만 설정을 저장하고, 표시 모드는 북마크나 파일 이동 서비스에 접근하지 않습니다.

포인터 위치의 `NSScreen.frame / visibleFrame / safeAreaInsets`를 AppKit point 좌표로 계산합니다. 메뉴바 아래 8pt 간격을 두며 음수 화면 원점도 처리합니다. 숨김 상태에서는 포인터가 있는 화면으로 진입 영역을 옮깁니다. 드래그 도중 디스플레이 구성이 바뀌면 세션을 취소합니다. 전체 화면 입력창, 비공개 API, Finder 주입, 전역 클립보드 폴링은 없습니다.

## 추천과 파일 안전

`FolderRecommendations`는 기존 규칙과 기록을 연결하는 작은 어댑터입니다. 연결한 정리 위치, 그 안에 **이미 존재하는** 규칙별 폴더, 기존 완료 기록의 목적지만 검사합니다. 고정 루트·설정된 분류 폴더·최대 24개 최근 경로를 백그라운드에서 캐시하며 전체 디스크를 조사하지 않습니다.

우선순위는 기존 이름 규칙 일치 → 완료된 이동의 최근 폴더 → 연결한 고정 정리 위치입니다. 최근·고정 근거를 카드에 그대로 표시하고 신뢰도나 AI 분석을 꾸미지 않습니다. 실패·취소·Undo 상태는 최근 선택의 근거로 사용하지 않습니다. 중복 경로·동일 디렉터리 identity·원본 부모를 걸러내고 동률은 시각과 경로로 안정적으로 정렬합니다.

**드래그 중에는 파일 시스템 검사도 하지 않습니다.** 실제 테스트에서 가벼운 메타데이터 조회가 TCC 창을 띄울 수 있어, 드래그 중 처리는 캐시와 파일명만 사용하도록 했습니다. 본문 읽기·OCR·네트워크·동기 디렉터리 순회가 없습니다. 연결·기록 변경 및 대기 중 30초 주기로 캐시를 갱신합니다. 사라진 폴더는 다음 캐시 갱신에서 제외되며, 이미 표시한 카드가 사라져도 위치를 바꾸지 않고 드롭 후 거절합니다.

`performDragOperation`의 수락은 파일 전달 수락입니다. 실제 파일 검사와 이동은 `draggingEnded` 이후 실행하며 콜백 누락 때는 마우스가 놓인 상태를 확인한 제한된 후속 처리로 진행합니다. 실제 일반 파일 여부·존재·이름 충돌·부모 권한·같은 볼륨·기존 보호 규칙·참조 관계를 다시 검사합니다. 파일 종류 확인이 필요한 폴더·별칭 등의 거절도 이 단계에서 확정됩니다.

오버레이용 계획과 기록에는 optional `destinationParentIdentities`를 추가했습니다. 이 값이 있는 실행은 목적지 부모 폴더를 만들지 않으며, 검사 후 폴더가 교체돼도 실제 쓰기 단계의 fd identity 검사에서 거절합니다. 기존 계획과 기록은 새 키가 없어도 그대로 해석됩니다. 동명 파일은 사전 검사뿐 아니라 실제 `RENAME_EXCL` 쓰기 단계에서도 보호합니다.

Undo는 기존 스냅샷·inode·내용·원래 위치 충돌 검사를 사용합니다. 앱에 자동 정리 감시기가 없으므로 통합할 이벤트 억제 서비스도 없습니다. 이동과 Undo가 같은 한 개 기록을 갱신하는지 테스트했으며 새 감시기나 재정리 경로를 추가하지 않았습니다.

## 권한

기존 앱은 Sandbox entitlement가 없는 로컬 ad-hoc 서명 앱입니다. 이 빌드 정책을 바꾸지 않았으며 전체 디스크 접근·손쉬운 사용·입력 모니터링을 제품의 요구 권한으로 추가하지 않았습니다.

정리 위치와 사용자가 직접 연결한 폴더의 security-scoped bookmark는 계속 재사용합니다. 저장된 연결은 재실행 시 `withoutUI`로 복원하며 stale·다른 경로로 해석된 연결은 인정하지 않습니다. 원본 파일은 사전 등록 없이 기존 부모 경로를 사용하고, 연결된 상위 폴더가 있으면 기존 참조 검사 범위를 유지합니다. 연결이 없으면 원래 부모 폴더를 계획의 기준 경로로 저장합니다. 파일의 원래 전체 경로와 폴더 identity는 기존 기록에 남아 재실행 후 Undo에도 사용됩니다. 실제 읽기·원본 부모의 이동/삭제 권한·목적지 쓰기 권한은 계속 확인하며, 운영체제의 접근 거부 오류에만 연결 안내를 덧붙입니다. 사라진 파일·경로 변경·충돌은 연결 문제로 표시하지 않습니다.

이 Mac에서는 다운로드 파일 이동에 **macOS 다운로드 폴더 접근 허용**이 별도로 필요했습니다. 시스템 요청은 최종 구현의 드래그 종료 후 검사 단계에서 나타났으며 이를 허용해 이동·재실행 후 Undo까지 확인했습니다. 권한을 허용하지 않으면 해당 위치의 이동이 제한됩니다. 권한이 필요한 위치를 사용하지 않고 일반 접근 가능한 연결 폴더를 사용하는 경로도 유지됩니다. 드래그 중 앱이 폴더 선택 모달을 띄우지 않으며, 실패 후 사용자가 연결 버튼을 눌러 기존 화면을 엽니다.

검증용 CGEvent 드래그 도구는 테스트 호스트의 기존 자동화 권한으로 동작합니다. 이 도구나 권한은 제품에 포함되지 않습니다.

## 초기 탭 버전 검증 (과거 근거)

아래는 초기 버전의 검증입니다. 12pt 진입 영역과 마지막 창을 닫으면 종료되는 동작은 이후 변경됐습니다. 최신 동작 검증은 아래 메뉴바·중앙 스냅 절을 따릅니다.

환경: Intel Mac, macOS **26.5.2 (25F84)**. 실제 화면은 Built-in Retina Display 한 대, 2048×1280pt, **backingScaleFactor 2**, safe top 0입니다. `verification/overlay/screens.json`에 실제 값을 보관했습니다.

| 구분 | 결과 / 증거 |
| --- | --- |
| 변경 전 기존 테스트 | 29개, 실패 0 — `overlay-baseline-tests.log` |
| 기능·회귀 테스트 | **49개, 실패 0**, 135.737초 — `overlay-final-tests.log` |
| 상세 구성 | 기존 Core 25 + Motion 4, 새 Overlay Core 15 + 설정 호환성 2 + pipe 통신 3 |
| 최종 release 빌드·서명 검사 | `scripts/build-app.sh` 성공 — `overlay-release-build.log` |
| 기존 설정·기록 | 새 optional 필드가 없는 이전 설정/계획/내역 decode 및 기존 이동·Undo 통과 |
| 추천 | 규칙/최근/고정 순서, 동률, 중복·원본 폴더·접근 불가·사라진 목적지 필터, 가짜 폴더 미생성 |
| 세션 | 후보 고정, 늦은 토큰 무시, 반복 콜백 한 번만 실행 |
| 실제 쓰기 | 12개 경쟁 이동에서 목적지 한 개만 성공; 검사 후 동명 충돌·목적지 교체 거절 |
| 실제 Finder | 파일 URL과 move 허용 수신. 세 카드 각각 실제 이동 후 동일 inode·SHA-256으로 Undo |
| 포커스·취소 | 12초 이상 호버와 세 카드 이동 중 Finder 유지, 실제 Esc 취소·카드 밖 드롭 시 원본 보존 |
| 완료 UI | 완료 문구, 폴더 열기로 실제 선택 경로 열기, UI Undo 확인 |
| 충돌 UI | 동명 목적지 충돌 시 두 파일 보존·새 성공 기록 없음. Undo 충돌 보존 후 재시도 복구 |
| 미지원 UI | Finder의 폴더, 5개 항목 드래그, 일반 텍스트 입력 거절. 파일 변경 없음 |
| 사라진 목적지 UI | 후보 표시 후 빈 테스트 폴더를 다른 위치로 옮겨 검사. 폴더 재생성·파일 이동 없음 |
| 사라진 원본 UI | 드래그 중 원본 경로가 바뀐 경우 취소되고 파일 변경 없음 |
| 권한 거절 UI | 연결된 원본 폴더를 쓰기 불가로 바꿔 실제 드롭. 부모 이동/삭제 권한 오류, 원본 보존, 새 기록 없음 |
| 일반 실행 + 다운로드 | 실제 기존 폴더 선택 → 북마크 저장 → 외부 드롭 → 이동 완료 → 앱 종료/재실행 → 기존 기록에서 Undo 확인 |
| 바탕화면 | 실제 Desktop 아이콘 URL 수신, 단순 선택 시 탭 유지, Finder 포커스 유지, 미연결 원본 안내와 원본 보존 확인. **연결 후 Desktop 파일의 실제 이동은 미검증** |
| 종료·끄기 | 토글 끔 시 표시 프로세스만 종료하고 메인 창 유지. 켠 채 마지막 주 창을 닫으면 두 프로세스 종료. 저장된 토글로 재실행 확인 |
| 화면 계산 | 다중 화면 배치의 음수 원점·메뉴바·노치 safe area를 단위 테스트. 실제 Retina 2배 단일 화면 배치 확인 |

주요 UI 증거: `verification/overlay/native-drag-summary.json`, `overlay-trace-agent-v1.jsonl`, `agent-first-move.json`, `agent-first-undo.json`, `undo-collision-ui.json`, `normal-download-file.json`, `normal-restart-undo-record.json`, `lifecycle.json`.

통신 테스트에서 긴 미완성 메시지를 매 조각마다 다시 검색하던 비용을 수정했고, oversized·잘못된 JSON·EOF 테스트가 통과했습니다. 마지막 수정은 원본 폴더 연결 안내 두 문구를 쉬운 표현으로 다듬은 것이며 최종 release를 다시 빌드했습니다.

## Dock 수정 검증 — 2026-09-10 05:16 KST

위의 초기 탭 버전 검증은 기존 이동·권한 회귀 근거로 보관했습니다. 이번 Dock 수정에서는 아래를 새로 확인했습니다.

| 항목 | 이번 검증 결과 |
| --- | --- |
| 전체 자동 검사 | `swift test -j 4` **53개 통과, 0 실패**. 기존 49개와 새 화면·배치·모서리·드롭 영역 검사 4개. 설정 round-trip에 Dock 배치도 추가 |
| 최종 release | `scripts/build-app.sh` 성공, ad hoc 서명 strict 검증 성공, 컴파일 경고 없음 |
| 완전 숨김과 진입 | 실제 Finder 파일로 투명 12pt 진입 영역 수신 → 폴더 Dock 표시. 눈에 보이는 정리 탭 없음 |
| 실제 이동·Undo | 전용 fixture 1개를 Setly 폴더로 이동 후 Dock의 되돌리기 성공. 기존 기록 하나가 `undone`, 원본 inode와 SHA-256 보존 |
| 포커스 | 기본 Dock 및 편집한 Dock 각각 12초 실제 Finder 드래그 유지, Finder가 계속 frontmost |
| 위치·크기 편집 | 빈 상단을 드래그해 이동; 오른쪽 아래 모서리로 resize. 실제 650×268pt로 바뀐 Dock의 폴더 hover와 Esc 취소 확인 |
| 취소 후 숨김 | Esc 뒤 650×12pt 수신 영역만 남고 콘텐츠·배경·그림자는 사라짐. 추가 이동 기록 없음 |
| 재실행 저장 | 일반 실행에서 650×240pt, 화면 좌표 (684, 191)로 편집 → 종료 → 재실행. 처음에는 숨김, 편집 버튼으로 **같은 프레임 복원** |
| 편집 중 끄기 | 토글을 끄면 표시 프로세스가 종료되고 주 앱은 유지. 다시 켜면 편집 없이 숨김으로 시작 |
| 기본값 복구 | 검증한 배치를 기본값으로 복구. 기존 사용자 규칙·폴더 경로·북마크·기능 켬 상태는 유지 |
| 접근성 설정 | 현재 `reduceMotion=false`, `reduceTransparency=true`를 AppKit으로 읽음. 현재 캡처는 시스템의 불투명 대체 재질. 투명도 줄이기를 끈 상태의 실제 블러, 동작 줄이기를 켠 실제 모션은 미검증 |

증거: `verification/overlay-dock/{tests.log,release-build.log,drag-trace.jsonl,hidden-entry-drag.log,resized-drag.log,after-cancel-windows.log,restart-hidden-windows.log,restart-edit-windows.log,restarted-edit.png,results.json}`. 실제 이동은 `/private/tmp/MaterialOrganizer-Dock-20260910`의 생성한 테스트 파일로만 수행했습니다. 시스템 접근성 설정을 바꾸지 않았습니다.

이번 수정 파일: `Sources/MaterialOrganizer/{AppModel,HistoryAndRules,FolderOverlayController,FolderOverlayView,FolderOverlayHost,FolderOverlayTransport}.swift`, `Tests/MaterialOrganizerTests/SettingsCompatibilityTests.swift`, 새 `Sources/OrganizerCore/FolderDockLayout.swift`, 새 `Tests/OrganizerCoreTests/FolderDockGeometryTests.swift`. 기존 이동 엔진·안전 검사·기록·Undo 구현은 수정하지 않았습니다.

## 메뉴바·중앙 스냅·감지 영역 수정 검증 — 2026-09-10 06:03 KST

| 항목 | 최신 결과 |
| --- | --- |
| 전체 검사 | **57개 통과, 0 실패**, 80.736초. 감지 영역 일치, 두 축 스냅 진입·유지·해제, 음수 화면 원점, 화면 안 제한, 모서리 비율, 소수 크기 반복 저장 검증 포함 |
| 최종 release | `scripts/build-app.sh` 성공 (38.02초), `codesign --verify --deep --strict` 성공, 컴파일 경고 없음 |
| 메뉴바 | 실제 폴더 아이콘과 주요 기능 메뉴 표시. 편집 시작, 기능 끔/켬, 정리 내역, 종료 확인. 폴더 연결 하위 메뉴에서 기존 원본 폴더 선택 창을 열고 취소 |
| 중앙 스냅 | 기본 520×196pt 프레임이 (764, 542), 확대한 780×340pt 프레임이 (634, 470)에 정렬. 두 경우 모두 중심 (1024, 640). 두 안내선 표시 및 드래그 종료 후 제거 확인 |
| 둥글기 | 기본 반경 20pt에서 340pt 높이의 반경 약 34.69pt로 비례 변경. 실제 확대 화면과 모서리 핸들 확인 |
| 감지 영역 | 편집 완료 후에도 숨김 창이 같은 (634, 470), 780×340pt. 화면 상단에 가지 않고 Finder의 (829, 320)에서 이동한 영역으로 진입해 폴더 표시 |
| 실제 이동·Undo | 전용 Setly 테스트 파일 이동 후 Dock에서 되돌림. 기록 1개가 `undone`, inode 121492746 및 SHA-256 유지. 12초 호버 중 Finder frontmost 유지 |
| 창 수명 | 주 창을 닫은 뒤 주 프로세스와 표시 프로세스 유지. 메뉴의 정리 내역에서 주 창 1개 다시 열림. 미연결 파일 거절 안내의 폴더 연결 버튼에서도 닫힌 규칙 창 다시 열림 |
| 기능 수명 | 메뉴에서 끔 → 표시 프로세스 종료, 켬 → 표시 프로세스 1개와 같은 숨김 배치 복원. 메뉴의 종료 → 두 프로세스 모두 종료 |
| 사용자 설정 | 전용 demo fixture에서만 편집·이동. 일반 앱 재실행 직후 전체 Settings JSON이 사전 사본과 동일함을 확인. 사용자가 저장한 780.4254150390625×340pt, horizontal 0.4700760147645667, vertical 0 보존. CGWindowList의 정수 bounds는 781×340pt로 보고됨. 이후 외부에서 바뀐 배치값도 덮어쓰지 않고 보존 |

증거: `verification/overlay-menu-snap/{final-tests.log,final-release-build.log,center-held-windows.log,resized-center-windows.log,center-guides.png,resized.png,status-menu.png,hidden-moved-windows.log,moved-area-drag.log,moved-area-hover.png,drag-trace.jsonl,undo-result.json,reopened-history-windows.log,menu-off-processes.log,menu-on-processes.log,pre-restart-state.json,settings-before.json,settings-after.json,final-normal-windows.log}`.

이번 변경 파일: `Sources/MaterialOrganizer/{App,AppModel,OrganizerStatusMenu,HistoryAndRules,FolderOverlayController,FolderOverlayView,FolderOverlayHost}.swift`, `Sources/OrganizerCore/FolderDockLayout.swift`, `Tests/OrganizerCoreTests/FolderDockGeometryTests.swift`. 이번 검증은 일반 데스크톱·Retina 2배 단일 화면 기준이며, 전체 화면 앱의 Space에서는 UI 전환이 즉시 확인되지 않아 일반 데스크톱에서 진행했습니다. 전체 화면/Spaces 호환성을 새로 보장하지 않습니다. 기존 이동 엔진·권한 검사·기록·Undo 코드는 이 수정에서 바꾸지 않았습니다.

## 바깥 핸들 수정 검증 — 2026-09-10 11:10 KST

- 최종 핸들은 검은색, 모서리에서 12pt 거리, 4pt 굵기, 둥근 캡입니다. 크기를 늘리면 호의 반경만 증가하고 선 길이는 13πpt(약 40.84pt)로 유지됩니다.
- 최종 기하 검사 **11개 통과, 0 실패**. 실제 CGPath의 길이·윤곽과의 거리, 히트 영역, 버튼 입력 구간, 편집 여백과 저장 프레임 분리 확인. 전체 59개 통과 기록은 마지막 색상·간격·고정 길이 수정 전 결과입니다.
- 최종 release 빌드 **43.50초 성공**, strict 서명 검증 성공. 실제 앱에서 기본 520×196pt와 확대 740×340pt 모양, 네 모서리 resize와 반대쪽 모서리 고정, 기본값·완료 버튼 확인.
- 중앙 이동 후 실제 본체 (764, 542), 520×196pt 확인. 마우스 해제 뒤 안내선이 사라지고, 완료 뒤 투명 감지 창이 같은 본체 프레임으로 돌아옵니다. 바깥 선이 메뉴바에 가려지지 않도록 가장자리 여백을 16pt로 확보했습니다.
- 전용 demo에서만 배치를 조작했습니다. 일반 앱을 최신 빌드로 다시 실행하고 편집 화면을 열었으며, 전체 사용자 Settings JSON이 사전 사본과 동일합니다. 이번 수정에서는 파일 이동·Undo를 다시 실행하지 않았습니다.

증거: `verification/overlay-handles/{constant-length-tests.log,black-release-build.log,black-default.png,black-large.png,bottom-right-windows.log,top-left-windows.log,top-right-windows.log,bottom-left-windows.log,center-released-windows.log,hidden-windows.log,final-normal-windows.log,final.png,results.json}`. UI 도구의 드래그 후 마우스 버튼 유지가 관찰되어 기존 검증용 CGEvent 도구로 버튼 해제만 보완했습니다. 제품 코드의 입력 우회는 추가하지 않았습니다.

이번 수정 파일: `Sources/OrganizerCore/FolderDockLayout.swift`, `Sources/MaterialOrganizer/{FolderDockResizeHandles,FolderOverlayView,FolderOverlayController,FileDragReceiver}.swift`, `Tests/OrganizerCoreTests/FolderDockGeometryTests.swift`.

### 후속 선 길이 조정 — 2026-09-10

사용자 요청에 따라 핸들의 고정 선 길이를 13πpt에서 9.75πpt(약 30.63pt)로 25% 줄였습니다. 검은색, 12pt 간격, 4pt 굵기와 둥근 캡은 그대로입니다. 최종 기하 검사 11개 통과, 0 실패. 증거는 `verification/overlay-short-handles/`에 보관했습니다.

### 핸들 두께·외곽선 조정 — 2026-09-10

핸들 두께를 6pt로 변경하고 Dock 외곽선(`borderWidth`)을 제거했습니다. 선 길이, 검은색, 12pt 간격, 둥근 캡은 유지합니다.

### 폴더 중심 레이아웃 — 2026-09-10

영역 내부의 헤더·안내·버튼을 외부 안내 바로 옮겼습니다. 외부 바는 영역 아래 16pt 위치에 놓이고 화면 아래에 공간이 없으면 위로 이동합니다. 폴더 아이콘과 이름 묶음은 카드의 가로·세로 중앙에 배치합니다. 저장 프레임·숨김 감지 프레임과 기존 파일 이동 동작은 그대로 사용합니다. 사용자 요청에 따라 추가 검사와 UI 검증은 생략합니다.

### 안내 및 버튼 배치 조정 — 2026-09-10

핸들의 검은 선을 본 영역과 동일한 NSVisualEffectView popover 재질로 바꾸었습니다. 곡선 마스크로 굵기·길이·캡을 유지합니다. 안내 문구는 본 영역 상단에 가운데 정렬하고, 외부 컨트롤의 배경·공통 그림자를 제거하여 버튼 자체만 영역 밖에 표시합니다. 추가 검사 및 UI 검증은 사용자 요청에 따라 생략합니다.

### 반투명 폴더와 내부 파일 — 2026-09-10

사용자가 제공한 폴더 레퍼런스에 맞춰 뒤판, 살짝 드러나는 실제 파일, 블러 처리한 앞판으로 구성한 네이티브 폴더 아이콘을 적용했습니다. 첫 추천은 블루, 나머지는 블랙이며 hover와 관계없이 추천 순서로 색상을 정합니다. 폴더 이름 가운데 정렬과 기존 드롭 영역을 유지합니다.

주 앱이 연결된 카탈로그를 갱신할 때 폴더별 최상위 항목을 최대 64개 살펴 일반 파일을 최대 3개 표시합니다. 이미지 파일은 96px 썸네일, 나머지는 파일 형식 아이콘을 사용하며 이미지가 없는 폴더에 가짜 파일을 넣지 않습니다. 이미지 읽기는 최대 16MiB, 썸네일은 파일당 4KiB이며 기존 폴더 권한·identity·비로컬/미다운로드/링크 제외 검사를 사용합니다. 표시 프로세스에는 파일 내용 대신 작은 미리보기 데이터만 전달합니다. 새 타이머와 드래그 중 파일 읽기는 추가하지 않았습니다. 사용자 요청에 따라 추가 검사와 UI 검증은 생략합니다.

## 재현 명령과 남은 확인

프로젝트 폴더에서 실행합니다.

```sh
swift test -j 4
scripts/build-app.sh
open dist/TILES.app
```

실제 드래그를 반복하는 검증 도구는 제품에 연결되지 않습니다. 아래 `verification/` 도구·캡처·로그는 로컬 검증 자료로 Git에서 제외되므로 새로 받은 저장소에는 포함되지 않습니다. 화면을 먼저 보고 현재 좌표를 지정해야 합니다.

```sh
swiftc verification/overlay/DragFixture.swift -o verification/overlay/drag-fixture
verification/overlay/drag-fixture drag SOURCE_X SOURCE_Y ENTRY_X ENTRY_Y FOLDER_X FOLDER_Y hold
verification/overlay/drag-fixture up FOLDER_X FOLDER_Y
```

`hold`는 12초 동안 RunLoop를 처리하며 실제 frontmost 앱을 기록합니다. 예전 cliclick 릴리스 동작과 RunLoop를 처리하지 않은 포커스 로그는 최종 증거로 사용하지 않았습니다. 프로토타입 수신부는 URL 전달 시점 확인용이며 장시간 포커스 보장의 근거가 아닙니다.

남은 수동 검증:

- **실제 두 대 이상의 모니터**, 서로 다른 배율의 화면 이동, 물리 노치 장비. 이 Mac에는 해당 장비가 없습니다.
- 전체 화면 앱, 별도 Spaces, Stage Manager, 외부 디스플레이 연결/해제 중 드래그. 시스템 동작을 가로채거나 미검증 지원을 보장하지 않습니다.
- macOS 14/15의 표시 프로세스·비활성 패널 동작. 최소 배포 대상은 14지만 현재 UI 실측은 26.5.2 한 버전입니다.
- 바탕화면 부모 폴더를 연결한 뒤 실제 Desktop 파일 이동. 넓은 연결 범위는 기존 코드·문서 참조 검사 한도 때문에 중단될 수 있습니다. 이 보호 정책은 유지했습니다.
- 실제 Finder 별칭·File Provider 미다운로드 파일·다른 볼륨·file promise 제공 앱별 입력, VoiceOver 전체 흐름. v1의 거절 정책은 코드와 단위 테스트로 검증한 범위만 보고합니다.

## 변경 파일

수정: `Package.swift`, `Sources/MaterialOrganizer/{App,AppModel,HistoryAndRules,Theme}.swift`, `Sources/OrganizerCore/{Models,Organizer,Planner,SafeFileSystem}.swift`.

추가: `Sources/MaterialOrganizer/{FileDragReceiver,FolderOverlayController,FolderOverlayView,FolderOverlayHost,FolderOverlayTransport}.swift`, `Sources/OrganizerCore/{FolderDropSession,FolderRecommendations}.swift`, `Tests/OrganizerCoreTests/FolderOverlayTests.swift`, `Tests/MaterialOrganizerTests/{SettingsCompatibilityTests,OverlayTransportTests}.swift`, 이 문서 및 `verification/overlay`의 검증 도구·증거.

`scripts/Info.plist`는 조사 전 사본과 동일합니다. 실제 이동은 전용 테스트 파일로만 수행했습니다. 다운로드 원본과 권한 시험에 쓴 디렉터리 모드는 복구했고, 초기 탭 버전 검증에서 만든 테스트 설정과 Undo 완료 기록은 별도로 보관했습니다. 이후 사용자가 저장한 현재 설정은 Dock 수정 전 사본과 비교해 배치 항목 외 기존 값을 유지했습니다. 파일 원본·연구·다른 프로젝트는 변경하지 않았습니다. 검증용 fixture와 실패한 초기 프로토타입 증거도 임의 삭제하지 않고 보관했습니다.

API 구분 참고: [NSDraggingDestination.draggingEntered](https://developer.apple.com/documentation/appkit/nsdraggingdestination/draggingentered(_:)), [draggingSourceOperationMask](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingsourceoperationmask), [performDragOperation](https://developer.apple.com/documentation/appkit/nsdraggingdestination/performdragoperation(_:)).

Dock 재질·동작 참고: [NSVisualEffectView](https://developer.apple.com/documentation/AppKit/NSVisualEffectView), [macOS Desktop & Dock 설정](https://support.apple.com/en-ie/guide/mac-help/mchlp1119/mac).

## 원본 위치 자동 인식 — 2026-09-10

원본 사전 등록 검사를 제거했습니다. 직접 부모에서 시작해 상위 프로젝트·패키지 보호도 확인하므로 등록되지 않은 하위 폴더가 기존 보호 정책을 우회하지 않습니다. 이동 기록 및 Undo 형식은 유지합니다. 실제 권한 부족은 폴더 연결 안내를 표시하고, 일반 실패 동작 버튼은 `설정 및 내역`으로 표시합니다. 기존 테스트는 미등록 원본 이동·기록 재로딩 후 Undo, 실제 권한 거부, 상위 프로젝트 보호와 목적지 범위에 맞춰 갱신했습니다. 이번 수정에서는 요청한 빠른 반영을 위해 테스트 실행과 드래그 UI 검증을 생략하고 실행 앱 빌드 및 교체만 진행합니다.
