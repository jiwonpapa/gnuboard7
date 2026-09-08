# 선택 항목 확장 API v1

engine-v1.65.0에서 `G7Core.layoutEditor.registerPanel(id, {label, render})`를 추가한다.
ID는 `vendor/panel` 형식이며 재등록은 교체, `null`은 해제다. 기존 ready 큐를 사용하며 등록 오류·패널 렌더 오류는 다른 확장에 전파하지 않는다. React/ReactDOM/JSX runtime은 호스트 전역을 공유한다.

패널 `render({host})`의 protocol은 `g7.layout-editor/1`이다. snapshot은 선택 없거나 로드 실패 시 null이다. 존재하면 node와 context는 분리 복사 후 재귀 동결된다. context는 templateIdentifier, layoutName, editMode, sessionId, revision, lockVersion, readonly, nodeId, path를 포함한다. 경로는 `number | {responsive:string}` 배열이다. session은 라우트·모드·재로드로 교체되고 revision은 로컬 변경 및 Undo/Redo마다 증가한다. 서버 lockVersion과 별개다.

`host.execute({expected: snapshot.context, kind:'setText', text})`는 같은 선택·세션·revision에서 route 소유 평문만 변경한다. `insertChild`는 같은 expected와 node, index를 받고 선택 노드의 children에 삽입한다. v1은 nesting이 허용한 basic 조합만 지원하며 기존 ID 중복, 출처 지정, responsive/iteration 조합은 거부한다. 이 제한은 후속 구조 편집 요구를 영구 제외하는 정책이 아니다.

반환은 applied/noop/refused이며 refused는 reason을 포함한다. 성공한 변경만 기존 문서와 이력에 반영한다. snapshot은 내보내기에 사용할 수 있지만 문서 저장 엔진이나 mutable store를 공개하지 않는다. 네이티브 저장은 기존 G7 저장 버튼과 서버 정책을 따른다.

NodeEditorProps/WidgetProps/CanvasOverlayProps의 선택형 extensionHost도 같은 계약이다. 기존 onPatchNode를 권한 검사 API로 오인하지 않는다. 새 확장은 execute를 사용한다. 기존 onInsertChild는 canonical 문자열과 ComponentPath를 받으며 가상 iteration 경로·잘못된 경로를 거부한다.

지원: 현재 route 일반 페이지, ID가 있는 직접 소유 노드. base/partial/extension/반복 인스턴스와 다른 모드는 v1 변경 대상이 아니다. 전체 저장 충돌·원격 권한 변경의 최종 판정은 기존 서버 API가 담당한다.

검증: extensionHost.test.tsx, useLayoutDocument.test.ts, useLayoutDocument.patchDocumentRaw.test.tsx, useLayoutDocument.saveGuard.test.tsx. 실제 PB 소비자의 저장·재열기 증거는 PB NE1 감사에 별도로 기록한다. 이 코드는 G7 로컬 확장 후보이며 upstream에 포함되었다고 주장하지 않는다.


## NE2 additive capabilities (engine-v1.66.0)

`snapshot.fields` exposes detached field descriptors from the currently merged editor spec. Each field includes `id`, translated `label`, `kind`, `group`, scalar `value`, `options`, `editable`, `custom`, and `source`. Finite style presets reuse the existing recipe engine. Missing means the original/template default remains active; reset removes only that field/group. Unmatched custom values are preserved until the user deliberately changes that control. Bound source/targets stay readonly. No arbitrary CSS/HTML/JS input is added. The standard basic Img also has host-owned `core:image-ratio` and `core:image-fit` finite CSS presentation controls, only when the template declares its source field. Installed template files are not changed.

`execute({kind:'setControl', expected, control, value, reset?:boolean})` revalidates context and the live spec, then patches once and pushes one existing history entry. Empty alt is an explicit empty string; reset removes alt. Literal links accept HTTP(S), site-absolute, fragment, mailto and tel URLs; image sources accept HTTP(S) or site-absolute URLs. Unknown/protected controls or expressions are refused without mutation.

`host.media.list({expected,scope:'page'|'template',signal?})` and `host.media.upload({expected,file,signal?})` call the existing authenticated attachment client. Page filters and upload ownership use the captured layout; template scope omits the layout filter. Results are `{ok:true,data}` or `{ok:false,reason}` and are revalidated after completion. Cancel cannot promise server-side file deletion if the server already accepted the upload. Neither method applies a node or deletes an attachment. Consumers must explicitly select a returned asset with setControl. All media is optional; older consumers and hosts keep the NE1 text workflow.

Current extension panel edits common/base styles. Existing responsive/dark overrides are preserved; extensions do not infer arbitrary spec/renderer or array support. Further editing scope is tracked separately in NE3/NE5.

## NE3 structure capability (engine-v1.67.0)

`snapshot.collections` enumerates the selected node's declared slots with opaque `id`, label, kind (children/array/cell), editable status, allowed seed choices and item fields. Slot ids belong to the exact accompanying context; do not parse them into ComponentPath or persist them. The host enumerates the current merged component capability, palette defaultNode and nesting spec on every command. Missing/opaque collections cannot be overwritten. `array`, `array-group`, `array-cell-tree` and declared children use their actual storage shape. An array `image` field is consumed by this capability; registering a widget does not change the old ArrayItemsEditor.

`execute({kind:'structure',expected,change})` accepts insert(collection,choice,index), delete/duplicate(collection,index), move(collection,index,destination,toIndex) and field(collection,index,field,value). Moves use pre-removal insertion coordinates, support declared node slots and forbid cycles. Different array record contracts cannot be interchanged. Identities and supported DOM references are remapped on duplication; unresolved references refuse the whole operation. Deleting a still-referenced target and manipulating inherited/injected subtrees refuse without history. Only successful changes patch the host document and push one history entry. Selection remains on the original anchor.

`iterationRoot` is present only in the host's existing iteration_item mode. Only the route-owned original template subtree can be modified; rendered instance indexes do not identify stored nodes. The iteration definition and external host content remain protected, with the existing host save isolation. Bound field values remain readonly. A raw route view of an iteration is not editable through this capability. Context changes invalidate commands and media responses. No template files, renderer registry, page routes or server permissions are rewritten by these APIs.

Native collection identity uses `id`. A spec with a different `idField` is not exposed to native structure commands; its original source and existing editor remain intact. Supporting another identity/reference contract requires an explicit adapter and tests.

## 선택 조합 재사용 (engine-v1.68.0 후보)

선택형 `host.compositions.export({expected,signal})`는 현재 선택의 `g7.editor-composition/v1` JSON 문자열을 반환한다. `insert({expected,snapshot,collection,index,signal})`는 그 문자열과 현재 snapshot의 불투명 collection ID를 받는다. 등록 전역 메서드는 추가하지 않는다.

템플릿/manifest/spec/nesting 서명의 정확 일치, 현재 renderer·G7 첨부 목록, 출처·ID·참조·허용 위치를 검증한다. 모든 비동기 완료 후 문맥을 다시 확인한다. 삽입은 기존 문서와 history 한 항목으로 적용하며 저장은 호출하지 않는다. 평문 구조는 같은 템플릿의 다른 페이지에 삽입할 수 있고 바인딩/actions/조건/외부 DOM 참조가 있으면 원래 layout으로 제한한다. 반복 모드·보호된 합성/상속 영역·비표준 구조의 내보내기는 현재 거부한다. 기존 원본을 삭제/정규화하지 않는다.

조합 저장소 구현은 확장 소유이며 이 계약은 PB API나 사용자 라이브러리 DB를 알지 않는다. G7 첨부 URL은 현재 템플릿의 실제 목록과 비교한다. 일반 정적/외부 URL의 원격 생존 여부 검사를 제공하는 계약은 아니다.

NE4 renderer 검증은 PreviewCanvas의 격리된 편집 대상 ComponentRegistry에서 전달한 manifest·hasComponent를 사용한다. 관리자 셸의 singleton registry를 편집 대상 registry로 간주하지 않는다.

NE4 출처 검증: 상속 슬롯의 route 노드는 실제 자식 layout 이름으로 표기한다. LayoutService는 부모 wrapper 소유와 자식 슬롯 소유를 별도로 전달한다. 기존 G7 content API의 빈 객체/배열 정규화는 PB 스냅샷 형식 보존과 별개이며, G7 저장 전후 전체 JSON 종류 보장은 후속 호환 감사 대상이다.
