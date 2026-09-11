# Hazel 6.1.2 실사용 검증과 TILES 반영 사항

> `verification/` 링크는 로컬 검증 자료를 가리키며 Git 저장소에는 캡처와 개인 경로가 포함된 원시 기록을 올리지 않습니다.

2026년 9월 11일, 사용자의 Mac에서 실행 중인 Hazel을 직접 조작했다. **규칙 작성 → 조건 미리보기 → 실제 이동 → 이름 충돌 처리 → Finder에서 되돌리기**를 임시 파일로 검증했고, 이어서 규칙 우선순위·비활성화·복사·수동 실행을 확인했다.

직접 사용한 결과 TILES가 우선 배워야 할 부분은 **판정에 사용한 값을 보여주는 방식, 변경 결과를 확인하는 방법, 복구와 실행 제어의 구분**이다. 기능 수를 늘리기 전에 이 흐름을 현재의 벤토 그리드 안에서 쉽게 사용할 수 있게 만드는 것이 적합하다. 이는 기능 시험에 근거한 제품 분석이며, 여러 초보 사용자를 대상으로 한 사용성 시험 결과는 아니다.

전체 기능과 아키텍처 제안은 [Hazel 분석과 TILES PRD](hazel-analysis-and-tiles-prd.md)에 통합했다. 이번에는 TILES 앱 코드를 변경하지 않았다.

## 1. 환경과 검증 경계

| 항목 | 확인 내용 |
|---|---|
| 설치본 | Hazel 6.1.2, build 2541. About 화면과 앱 번들 정보로 확인 |
| 실행 환경 | macOS 26.5.2, build 25F84, Intel x86_64 |
| 최소 OS 표기 | 설치된 앱 번들의 `LSMinimumSystemVersion`은 13.5. 공개 릴리스 페이지는 macOS 13으로 표기 |
| 라이선스 화면 | 현재 창에는 `Hazel is in trial mode. You have 14 days left.` 배너가 보였음. 구매·라이선스 보유 여부나 활성화 원인은 조사하지 않음 |
| 기존 감시 대상 | Downloads 한 개. 시험 직전의 기존 여섯 규칙은 모두 비활성 상태 |
| 시험 공간 | `/private/tmp/TILES-Hazel-Lab-e26e7de4`의 Inbox, Filed, Copies. 조사용으로 생성한 텍스트 파일만 사용 |
| 조작 방식 | 실제 Hazel/Finder 화면에서 규칙·조건·목적지·메뉴를 조작. 파일 생성과 해시 비교는 로컬 검사로 수행 |
| 종료 상태 | 시험용 Inbox 감시 등록과 임시 규칙을 제거. Downloads의 규칙 이름·개수·활성 상태와 폴더 일시정지 상태가 시험 직전과 일치 |

공개 버전 정보는 [Noodlesoft 릴리스 페이지](https://www.noodlesoft.com/release_notes)와 비교했다. 화면 조작에는 포커스 전환과 대화상자 대기 시간이 섞여 있으므로 이번 기록을 처리 속도나 사용자의 작업 소요 시간 측정으로 사용하지 않는다. 접근성 트리는 조작과 관찰에 활용했지만 VoiceOver·키보드 접근성 적합성 시험을 수행한 것은 아니다.

기존 규칙의 내용을 편집하거나 개인 파일에 시험 규칙을 적용하지 않았다. 앱 설정 파일 전체의 바이트 동일성을 주장하는 것은 아니며, 보존 검증의 범위는 [정리 전후 비교](../../verification/hazel-native-20260911/cleanup-verified.json)에 명시했다.

## 2. 실제 실행 결과

| ID | 조작·조건 | 관찰 결과 | 근거 |
|---|---|---|---|
| N-01 | 시험 Inbox 등록 후 Pause Rules | 폴더 옆 일시정지 표시와 Resume Rules 버튼을 확인. 규칙 자체의 체크 상태와 독립 | [일시정지 화면](../../verification/hazel-native-20260911/05-restored-and-paused.png) |
| N-02 | `Name starts with Invoice_`로 송장 미리보기 | `Rule matches` 표시. 조건의 체크 표시에서 실제 Name 값 확인 | [일치 화면](../../verification/hazel-native-20260911/03-preview-matched.png) |
| N-03 | 같은 조건으로 Notes 파일 미리보기 | `Rule does not match` 표시. 미리보기 전후 네 텍스트 파일의 경로·내용 해시 불변 | [불일치 화면](../../verification/hazel-native-20260911/03-preview-not-matched.png) |
| N-04 | Move to Filed 저장 후 감시 재개 | 송장 두 개만 이동. 메모는 Inbox에 유지. 같은 이름의 기존 목적지 파일은 보존하고 유입 파일에 `-1` 추가 | [이동 결과와 해시](../../verification/hazel-native-20260911/after-move-verified.json) |
| N-05 | Inbox 일시정지 후 Finder의 Revert를 각 송장에 실행 | 두 송장의 원래 경로와 이름 복구. 충돌로 붙었던 `-1`도 제거. 네 텍스트 파일의 경로·내용이 최초 상태와 일치 | [복구 결과와 해시](../../verification/hazel-native-20260911/after-revert-verified.json) |
| N-06 | 같은 접두어 규칙 두 개: 위쪽 Move→Filed, 아래쪽 Copy→Copies | 새 송장은 Filed로 이동하고 Copies에는 생성되지 않음. 위쪽 일치 규칙만 실행된 결과와 일치 | [규칙 순서 시험](../../verification/hazel-native-20260911/rule-order-verified.json) |
| N-07 | 폴더 일시정지 상태에서 Run Rules Now | 수동 실행이 수행됨. 앞서 되돌렸던 두 송장도 다시 이동. 폴더 표시 자체는 일시정지 유지 | [수동 실행 결과](../../verification/hazel-native-20260911/rule-order-verified.json) |
| N-08 | 위쪽 Move 규칙만 비활성화하고 새 송장으로 수동 실행 | 아래쪽 Copy 규칙 실행. 원본은 Inbox에 남고 Copies에 같은 해시의 사본 생성. Filed에는 해당 새 송장 없음 | [복사 대조 시험](../../verification/hazel-native-20260911/copy-verified.json) |
| N-09 | Action → Remove Folder에서 시험 Inbox 제거 | 시험 감시 등록과 두 임시 규칙 제거. 기존 Downloads 여섯 규칙의 이름·활성 상태 일치 | [종료 상태](../../verification/hazel-native-20260911/cleanup-verified.json) |

N-06은 Move 다음 Copy 조합에서 첫 일치 규칙이 실행된 것을 확인한 시험이다. 모든 동작 조합에서의 규칙 체인을 검증한 것은 아니다. N-08은 아래쪽 Copy 규칙 자체가 실행 가능한 설정이었다는 대조 시험이다. 일반적인 우선순위와 `Continue matching rules`의 의미는 [공식 규칙 로직 문서](https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/create-edit-rules/understand-the-logic-of-rules/)에 근거한 기존 분석과 함께 읽어야 한다.

## 3. 이동·충돌·복구에서 확인한 내용

첫 실험은 의도적으로 같은 이름의 목적지 파일을 미리 만들어 시작했다. 기존 파일에는 별도의 내용을 넣었으므로 단순히 파일 이름만 확인한 것이 아니라 각 내용의 보존 여부를 SHA-256으로 비교했다.

| 시험 파일 | 최초 위치 | 첫 이동 후 | 첫 Revert 후 |
|---|---|---|---|
| 송장 A | Inbox/Invoice_2026-09-11.txt | Filed/Invoice_2026-09-11-1.txt | Inbox/Invoice_2026-09-11.txt |
| 송장 B | Inbox/Invoice_2026-09-12.txt | Filed/Invoice_2026-09-12.txt | Inbox/Invoice_2026-09-12.txt |
| 일반 메모 | Inbox/Notes_2026-09-11.txt | 변경 없음 | 변경 없음 |
| 미리 있던 목적지 파일 | Filed/Invoice_2026-09-11.txt | 내용·이름·위치 보존 | 내용·이름·위치 보존 |

Move Options에서 선택되어 있던 기본 충돌 정책은 `rename the file`이었다. `replace the existing file`, `throw the file away`, 중복 폐기와 폴더 구조 복사 옵션도 보였다. 실제로 실행한 것은 이름 변경으로 충돌을 피하는 첫 번째 정책이다. 덮어쓰기·폐기는 시험하지 않았다.

![실제 Move 옵션](../../verification/hazel-native-20260911/02-move-options.png)

되돌리기는 이동된 파일을 Finder에서 우클릭해 `Revert`를 선택하는 방식으로 수행했다. 규칙 편집기 아래쪽의 Revert 버튼과 진입점이 다르다. TILES는 사용자가 두 의미를 구별하도록 결과 영역에 **이동 되돌리기**, 편집 영역에 **변경 취소**처럼 대상을 드러내는 표현을 쓰는 것이 좋다.

이동 복구가 성공했다고 해서 Copy·Sync·Upload·외부 자동화까지 되돌릴 수 있는 것은 아니다. 해당 기능의 복구 범위는 [공식 Revert 문서](https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/manage-rules/revert-a-file/)의 제한을 따른다. 이번 실험에서도 복사본을 Revert로 제거하는 시험은 하지 않았다.

복구 검증을 마친 뒤 N-06~08을 별도 수행했기 때문에 최종 시험 파일은 다시 이동·복사된 상태다. 각 단계의 판정은 해당 단계 JSON에 보존했고, 마지막 파일 상태도 [별도 보관](../../verification/hazel-native-20260911/final-fixture-state.json)했다. 개인 파일의 복구를 수행한 실험은 아니다.

## 4. 조건 미리보기는 특히 참고할 만하다

같은 규칙을 다른 대표 파일에 적용하면 조건 줄과 전체 결과가 함께 바뀐다. 송장은 초록 체크와 `Rule matches`, 메모는 빨간 표시와 `Rule does not match`로 나타났다. 색뿐 아니라 문구로도 결과를 구분한다.

![송장 파일의 조건 일치](../../verification/hazel-native-20260911/03-preview-matched.png)

![메모 파일의 조건 불일치](../../verification/hazel-native-20260911/03-preview-not-matched.png)

조건 옆 체크 표시를 눌렀을 때 실제 `Name` 값은 `Invoice_2026-09-12`로 표시됐다. 미리보기 대상 파일의 표시 이름에는 `.txt`가 있지만 해당 속성 값에는 확장자가 없었다. 규칙을 설명할 때는 ‘파일 이름’이라는 뭉뚱그린 표현보다 **무슨 값을 비교했는지**가 중요하다.

다만 이 미리보기는 실행 결과 화면이 아니다. 테스트 폴더를 정지한 상태에서 미리보기를 마친 뒤에도 원본·목적지 파일과 해시는 그대로였다. 목적지 쓰기 가능 여부나 충돌 해결까지 확인했다는 표시로 해석하면 안 된다. [공식 Preview 안내](https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/create-edit-rules/preview-a-rule/)

TILES에는 다음 두 결과를 연결해 보여주는 것이 적합하다.

1. **조건 검사:** 어떤 실제 값이 어느 조건에 맞았는지, 맞지 않았는지, 읽을 수 없었는지.
2. **이동 계획:** 최종 경로·이름, 충돌·보호·권한 확인 결과, 사용자가 승인할 변경.

실행 직전에는 파일과 목적지 상태를 다시 검사해야 한다. 미리보기 성공 이후 파일이 바뀌지 않았다는 보장은 없기 때문이다.

## 5. 현재 폴더 검사와 완료 기록은 역할이 다르다

Rule Status를 처음 열었을 때 Inbox의 송장 두 개에 일치 규칙이 표시되고 메모에는 일치 규칙이 표시되지 않았다. 이동 완료 후 새로고침하자 현재 Inbox에 남은 메모 한 개만 보였다.

이 관찰은 **현재 폴더를 검사하는 화면이 곧 모든 완료 작업의 장부는 아니라는 점**을 보여준다. Hazel에 다른 기록 진입점이 없다는 뜻은 아니다. 메뉴 막대 전체 이력의 범위와 보존 기간은 이번에 검증하지 않았다.

TILES의 기록은 원본 폴더에서 파일이 사라져도 다음 정보를 유지해야 한다.

- 어떤 파일을 어느 규칙 또는 사용자 선택으로 처리했는지.
- 실제로 도착한 최종 경로와 이름, 완료·실패·부분 처리 상태.
- 현재 되돌릴 수 있는 범위와 실행 결과.

관련 요구사항은 PRD의 FR-08, FR-09와 RunRecord·ExecutionLedger에 반영했다.

## 6. 화면에서 확인한 기능과 실행하지 않은 범위

| 항목 | 화면에서 확인한 사실 | 검증 한계 |
|---|---|---|
| 기본 동작 | 메뉴에 30종 존재. 공식 목록과 일치 | 실제 동작은 Move·Copy와 이동 Revert 중심으로 검증 |
| OCR 정책 | Use Text Recognition에 Always / As Needed / Never. 현재 기본 표시 As Needed | 이미지·스캔 문서 인식 정확도, 언어별 동작, 처리량 미검증 |
| PDF 암호 | Document Password 입력란과 Keychain 저장 안내 | 암호 입력·보관·잠금 해제 자체는 실행하지 않음 |
| 폴더 옵션 | Duplicate files, Incomplete downloads after 옵션. 시험 폴더에서는 둘 다 꺼져 있었음 | 중복 폐기·미완료 다운로드 폐기 미실행 |
| 규칙 메모 | 메모 표시 버튼과 메모를 검색에 활용한다는 안내 | 대규모 규칙 검색·내장 스크립트 검색 미실행 |
| 폴더 메뉴 | Add App Folder, Add Smart Folder, Add Folder Group, Rule Sync Settings, Replace Folder 존재 | 해당 폴더 종류 등록·참조 교체·규칙 동기화 미실행 |
| 규칙 관리 | Duplicate 메뉴로 시험 규칙 복제, 체크박스로 첫 규칙 비활성화 | 다른 Mac으로 내보내기·가져오기·동기화 미실행 |
| 레이아웃 | 폴더 목록·규칙 목록·편집기가 한 창에 있음. 관찰한 958pt 창과 열 너비에서는 폴더·규칙 이름이 많이 잘림 | 다른 창 크기·열 너비에서의 가독성이나 일반 사용자 성공률로 일반화하지 않음 |

설정 화면 증거: [OCR·암호 옵션](../../verification/hazel-native-20260911/08-rule-options.png), [폴더 옵션](../../verification/hazel-native-20260911/07-folder-options.png), [Folder 메뉴](../../verification/hazel-native-20260911/09-folder-menu.png), [30개 동작 목록](../../verification/hazel-native-20260911/action-menu-verified.json).

클라우드에만 있는 파일의 처리 옵션은 이번 로컬 임시 폴더 화면에서 검증하지 못했다. 이것이 제품에 해당 기능이 없다는 뜻은 아니다. 실제 File Provider 환경, PDF·OCR, 사용자 정의 패턴·표·목록, 다중 동작의 대상 전환, 업로드·동기화, 앱 가져오기, Shortcuts·스크립트, App Sweep, 휴지통 관리는 공식 문서 조사 범위에 남아 있다.

실패 후 자동 재시도, 앱 강제 종료 후 복구, 다른 볼륨 이동, 심볼릭 링크, 큰 파일, 동시 파일 유입도 별도 시험이 필요하다. 이번 작은 로컬 텍스트 파일 시험으로 그 신뢰성을 보장하지 않는다.

## 7. TILES의 제품 요구사항을 어떻게 보완했는가

| 우선순위 | 보완할 경험 | PRD 반영 |
|---|---|---|
| P0 | 이동 직전에 최종 파일명과 위치를 읽을 수 있음 | FR-07. 충돌로 이름이 달라지는 경우도 변경 전후 확인 |
| P0 | 결과·기록에서 이동 되돌리기를 바로 찾음 | FR-08. 규칙 편집 취소와 구별 |
| P0 | 파일이 떠난 뒤에도 결과와 복구 근거를 찾음 | FR-09. 현재 폴더 검사와 영속 기록 분리 |
| P1 | 조건에 사용한 이름·종류·날짜 값을 확인 | FR-12, FR-14. 확장자 포함 여부와 실제 비교 값 명시 |
| P1 | 조건 일치와 이동 가능성을 구분 | FR-15. 일치·불일치 대표 파일 시험 및 실행 전 재검사 |
| P1 | 규칙 여러 개가 맞는 상황을 이해 | FR-17 유지. 초기에는 목록 순서로 조용히 선택하지 않고 확인 대기 |
| P1 | 일시정지 중 수동 실행의 의미를 이해 | FR-18. 대상·예상 결과를 확인한 명령으로만 수동 실행, 전체 중지와 구별 |
| P2 | 내용 인식의 적용 범위와 추출 결과를 확인 | FR-24. 기존 텍스트 우선, 필요한 OCR과 읽기 실패 구분 |

현재 TILES의 벤토 그리드와 슬라이딩 퍼즐 모션은 유지한다. 카드 안에는 **선택 파일 → 목적지·이유 → 실제 결과**를 연결하고, 고급 조건과 동작은 필요한 시점에 펼치는 방향이다. 새 대시보드나 큰 설명 문구를 추가하는 근거로 사용하지 않는다.

Hazel의 규칙 우선순위는 규칙을 스스로 설계하는 사용자에게 일관된 실행 원리를 제공한다. 반면 TILES의 초기 고객 가설은 파일을 넣고 목적지를 고르는 사람이다. 따라서 첫 버전에서는 규칙 충돌을 사용자에게 드러내고, 명시적 순서 편집은 실제 수요를 확인한 뒤 도입하는 판단을 유지한다.

## 8. 산출물과 종료 확인

화면 11개, 환경·메뉴·파일 해시·복구·규칙 순서·복사·정리 검증 JSON, 최종 시험 파일 사본을 [검증 자료](../../verification/hazel-native-20260911/README.md)에 모았다. 시험용 감시 등록은 남아 있지 않으며 기존 Downloads 규칙은 시험 직전 상태와 일치한다.

이 보고서는 **실제 실행 검증**, **화면 존재 확인**, **문서 근거**, **TILES에 대한 제안**을 구분한다. 전체 Hazel 기능을 모두 실행했거나 TILES에 자동화가 이미 구현되었다는 의미는 아니다.
