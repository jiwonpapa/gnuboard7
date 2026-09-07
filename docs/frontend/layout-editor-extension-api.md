# 선택 항목 확장 API v1

engine-v1.65.0에서 `G7Core.layoutEditor.registerPanel(id, {label, render})`를 추가한다.
ID는 `vendor/panel` 형식이며 재등록은 교체, `null`은 해제다. 기존 ready 큐를 사용하며 등록 오류·패널 렌더 오류는 다른 확장에 전파하지 않는다. React/ReactDOM/JSX runtime은 호스트 전역을 공유한다.

패널 `render({host})`의 protocol은 `g7.layout-editor/1`이다. snapshot은 선택 없거나 로드 실패 시 null이다. 존재하면 node와 context는 분리 복사 후 재귀 동결된다. context는 templateIdentifier, layoutName, editMode, sessionId, revision, lockVersion, readonly, nodeId, path를 포함한다. 경로는 `number | {responsive:string}` 배열이다. session은 라우트·모드·재로드로 교체되고 revision은 로컬 변경 및 Undo/Redo마다 증가한다. 서버 lockVersion과 별개다.

`host.execute({expected: snapshot.context, kind:'setText', text})`는 같은 선택·세션·revision에서 route 소유 평문만 변경한다. `insertChild`는 같은 expected와 node, index를 받고 선택 노드의 children에 삽입한다. v1은 nesting이 허용한 basic 조합만 지원하며 기존 ID 중복, 출처 지정, responsive/iteration 조합은 거부한다. 이 제한은 후속 구조 편집 요구를 영구 제외하는 정책이 아니다.

반환은 applied/noop/refused이며 refused는 reason을 포함한다. 성공한 변경만 기존 문서와 이력에 반영한다. snapshot은 내보내기에 사용할 수 있지만 문서 저장 엔진이나 mutable store를 공개하지 않는다. 네이티브 저장은 기존 G7 저장 버튼과 서버 정책을 따른다.

NodeEditorProps/WidgetProps/CanvasOverlayProps의 선택형 extensionHost도 같은 계약이다. 기존 onPatchNode를 권한 검사 API로 오인하지 않는다. 새 확장은 execute를 사용한다. 기존 onInsertChild는 canonical 문자열과 ComponentPath를 받으며 가상 iteration 경로·잘못된 경로를 거부한다.

지원: 현재 route 일반 페이지, ID가 있는 직접 소유 노드. base/partial/extension/반복 인스턴스와 다른 모드는 v1 변경 대상이 아니다. 전체 저장 충돌·원격 권한 변경의 최종 판정은 기존 서버 API가 담당한다.

검증: extensionHost.test.tsx, useLayoutDocument.test.ts, useLayoutDocument.patchDocumentRaw.test.tsx, useLayoutDocument.saveGuard.test.tsx. 실제 PB 소비자의 저장·재열기 증거는 PB NE1 감사에 별도로 기록한다. 이 코드는 G7 로컬 확장 후보이며 upstream에 포함되었다고 주장하지 않는다.
