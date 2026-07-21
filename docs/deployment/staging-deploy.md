# 스테이징 배포

이 문서는 `ssh gnuboard7`로 접속 가능한 스테이징 서버에 G7 코드를 반영하는 로컬 실행형 배포 파이프라인을 설명합니다.

기본값은 아래와 같습니다.

- SSH 호스트: `gnuboard7`
- 원격 앱 루트: `public_html`
- 후처리 대상 모듈: `sirsoft-benchmark`

## 왜 이 방식으로 배포하는가

G7는 활성 확장 디렉토리(`modules/{identifier}`)를 Git 추적 대상에서 제외하고, `_bundled` 디렉토리를 배포 소스로 사용합니다. 따라서 배포 시에는 `_bundled`를 서버에 올린 뒤, 서버에서 `module:update --force` 또는 `module:install`/`module:activate`를 통해 활성 디렉토리에 반영해야 합니다.

관련 근거:

- [module-basics.md](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/docs/extension/module-basics.md)
- [extension-update-system.md](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/docs/extension/extension-update-system.md)
- [module-commands.md](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/docs/extension/module-commands.md)

## 추가된 파일

- [staging.sh](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/scripts/deploy/staging.sh)
- [staging.rsync-filter](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/scripts/deploy/staging.rsync-filter)

## 동작 순서

1. 로컬에서 저장소 전체를 `rsync`로 `gnuboard7:public_html`에 동기화합니다.
2. `.env`, `storage`, `bootstrap/cache`, 활성 확장 디렉토리(`modules/*`, `plugins/*`, `templates/*`)는 건드리지 않습니다.
3. 서버에서 `composer install --no-dev --optimize-autoloader --no-interaction`를 실행합니다.
4. 서버에서 `php artisan optimize:clear`와 `php artisan extension:update-autoload`를 실행합니다.
5. `sirsoft-benchmark` 모듈에 대해 아래 순서로 반영합니다.
6. 설치된 경우: `php artisan module:update sirsoft-benchmark --force`
7. 미설치인 경우: `php artisan module:install sirsoft-benchmark` 후 `php artisan module:activate sirsoft-benchmark`
8. 모듈 반영 후 `config`, `route`, `view`, `hooks` production 캐시를 재생성합니다.
9. 마지막으로 `php artisan queue:restart`를 실행합니다.

## 사용법

일반 배포:

```bash
bash scripts/deploy/staging.sh
```

사전 점검:

```bash
bash scripts/deploy/staging.sh --dry-run
```

원격 후처리 없이 파일만 올리기:

```bash
bash scripts/deploy/staging.sh --skip-remote-hooks
```

원격 루트나 호스트 오버라이드:

```bash
bash scripts/deploy/staging.sh --host gnuboard7 --root public_html
```

배포 대상 모듈 변경:

```bash
bash scripts/deploy/staging.sh --modules sirsoft-benchmark,sirsoft-board
```

환경 변수로도 같은 값을 바꿀 수 있습니다.

```bash
G7_REMOTE_HOST=gnuboard7 \
G7_REMOTE_ROOT=public_html \
G7_DEPLOY_MODULES=sirsoft-benchmark \
bash scripts/deploy/staging.sh
```

## 전제 조건

- 로컬에서 `ssh gnuboard7` 접속이 가능해야 합니다.
- 원격 서버에서 `public_html`이 G7 프로젝트 루트여야 합니다.
- 원격 서버에서 `php`와 `composer`가 PATH에 있어야 합니다.
- 큐 워커는 별도로 상시 실행 중이어야 합니다.
- 이 파이프라인은 새 서버 초기 설치가 아니라 기존 스테이징 서버 갱신을 전제로 합니다.

## 주의 사항

- `storage/`와 `.env`는 서버 상태를 보존하기 위해 동기화 대상에서 제외합니다.
- 활성 확장 디렉토리는 서버에서 관리되므로 직접 덮어쓰지 않습니다.
- `sirsoft-benchmark` 같은 신규 모듈은 반드시 `modules/_bundled/{identifier}`에 있어야 이 파이프라인으로 배포됩니다.
- `public/build`는 Git 추적 대상이라 함께 동기화됩니다.
