# Vault (hq_reader)

## Backend (API no servidor)

O backend FastAPI **não** fica dentro deste repositório. Está ao lado:

- Pasta: **`Documents\Projetos\valt-catalog-api\`**
- Código: apenas essa pasta (ou cópia no teu servidor 7).

Na app Flutter, aponta o URL do API com `--dart-define=VAULT_BACKEND_URL=https://…`

Instruções de arranque: `..\valt-catalog-api\README.md` (mesmo nível deste projeto na pasta Projetos).

### Apagar conta

A app chama **`DELETE`** `{backend}/auth/me` com o Bearer token da sessão; opcionalmente envia **`{"password":"…"}`** no corpo (confirmação no ecrã). O backend deve implementar esse endpoint para apagar o utilizador (e referências ligadas — cascata segundo a política) na base de dados.

Exemplo minimal (FastAPI + SQLAlchemy, adapta ao teu router de auth):

```python
@router.delete("/me")
async def delete_me(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    db.delete(current_user)
    db.commit()
    return Response(status_code=204)
```

Se quiseres validar a palavra-passe (`body` JSON opcional), faz `password: str | None` via `Body(embed=True)` ou modelo Pydantic e compara hash antes de `db.delete`.

Se ainda vires **`Valt-\server`** no disco antigo é uma pasta vazia ou bloqueada; podes apagá‑la manualmente (fecha IDE/terminal que esteja a abrir essa pasta).

## Modo leitura (PDF + voz)

O ecrã de leitura em voz mostra o **PDF completo** (como o leitor normal), com barra de controlo em baixo. Se ainda vires **só texto** num fundo escuro, o telemóvel está quase de certeza com um **APK antigo**.

1. Desinstala a app no telemóvel **ou** corre: `flutter run --uninstall-first`
2. Garante `version` em `pubspec.yaml` (ex.: `1.0.2+3`) — o número depois do `+` é o **versionCode** Android; tem de **subir** em cada instalação que queiras garantir que substitui a anterior.
3. Em **debug**, o `pdfrx` pode escrever no log o aviso do **PDFium WASM (~4 MB)**; em `flutter build apk --release` segue a [nota oficial do pdfrx](https://github.com/espresso3389/pdfrx/tree/master/packages/pdfrx#note-for-building-release-builds) para builds de produção.

## Build Android (Windows)

O `android/build.gradle.kts` de raiz ficou igual ao modelo Flutter (**sem** código extra em `plugins.withId`): truques lá podem disparar `Cannot run Project.afterEvaluate when already evaluated`.

- O módulo **`:app`** continua com `ndk.abiFilters` só `arm64-v8a` e `x86_64` (ver `android/app/build.gradle.kts`).
- Ao instalar só num **telemóvel ARM64**, podes pedir apenas essa variante ao Flutter e assim o Gradle compila menos coisa nativa (útil para o plugin `rar`):

  `flutter run --target-platform android-arm64`

- Se aparecer erro de CMake / “não consegui apagar pasta” na cache do pacote **rar**:

  ```powershell
  cd android; .\gradlew.bat --stop
  Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\rar-0.3.0\android\.cxx" -ErrorAction SilentlyContinue
  cd ..; flutter clean; flutter pub get; flutter run
  ```

- Se tens **Bluetooth** com o pacote `flutter_blue_plus` (mensagens **`[FBP]`** ou **“📶 Dispositivo encontrado”**), em `main()` após `ensureInitialized`:

  ```dart
  await FlutterBluePlus.setLogLevel(LogLevel.none); // menos ruído no log
  ```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
