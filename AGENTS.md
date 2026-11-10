# Oil Find

Ferramenta nativa de busca de arquivos para macOS, gratuita e de código aberto (o "Everything" do Mac); o painel de busca abre com ⇧⌘F. A arquitetura e os invariantes do índice estão em `docs/ARCHITECTURE.md`.

## Diretórios

- `Sources/COilFind/`: leitura de diretórios em lote em C, comparação de nomes e pontuação da busca.
- `Sources/OilFindCore/`: varredura, índice, consultas, atualizações em tempo real, persistência e atualização do aplicativo.
- `Sources/OilFindApp/`: biblioteca AppKit do app e configurações em SwiftUI; os textos da interface ficam em `L10n.swift` (somente inglês), e o ponto de extensão neutro é `ApplicationExtension`.
- `Sources/OilFind/main.swift`: ponto de montagem do app executável.
- `Sources/oilfind-cli/`: ferramenta de linha de comando para validação.
- `Tests/`: testes do motor, da interface do app e de scripts.
- `Resources/`: metadados do app e ícone.
- `build.sh`: entrada interativa de build (bump de versão, limpeza, preflight; `install` instala em /Applications para uso em produção).
- `scripts/`: build, empacotamento, instalação e desinstalação.
- `site/`: site oficial em Next.js App Router, demonstração de busca, changelog e manifest estático de atualizações.

## Build e testes

Deployment target macOS 14, voltado a Apple silicon.

```sh
./build.sh
swift build -c release
swift test
python3 Tests/Scripts/test_uninstall.py
python3 Tests/Scripts/test_open_core.py
scripts/build-app.sh
scripts/build-app.sh --debug
scripts/package.sh
```

`Pro/` mantém o nome de diretório dos módulos internos. A branch pessoal tem um único build, que sempre inclui a busca de conteúdo e não oferece checagem de atualização dentro do app.

O site usa Node.js 22 e pnpm:

```sh
cd site
pnpm install --frozen-lockfile
pnpm dev
pnpm test
pnpm build
```

## Convenções

- O app usa o modo de linguagem Swift 5 e um target C; apenas frameworks do sistema, sem pacotes de terceiros.
- A biblioteca pública do app e o core não podem depender de módulos privados; a integração é feita somente pela interface neutra `ApplicationExtension`. Apenas `Package.swift` e `Sources/OilFind/main.swift` podem mencionar targets privados, para declarar dependências e montar; a entrada não resolve estado nem parâmetros de funcionalidades privadas. A extensão fornece as interfaces de inicialização, encerramento, seção de configurações e URL; em DEBUG os próprios parâmetros podem ser pré-processados e removidos.
- Os caminhos quentes de varredura, busca e tratamento de eventos usam ponteiros Unsafe e layout SoA, sem criar String nem alocação em heap por item.
- Comentários de código em inglês. Os textos da interface ficam somente em inglês, no dicionário `L10n.swift`.
- Existe um único arquivo de índice; arquivos temporários são apagados após o uso. Sem a permissão de Acesso Total ao Disco, diretórios com EPERM são silenciosamente ignorados.
- A validação da interface usa `--snapshot` na build de debug; a release não inclui essa entrada.
- O site usa TypeScript, React e Next.js; as dependências de runtime são `next`, `react`, `react-dom`, `@vercel/analytics` e `stripe` (para a API de licenciamento); os lockfiles de npm e pnpm devem permanecer em sincronia.
- Não versionar arquivos de ambiente, segredos, pacotes baixados, índices ou artefatos de build. O CI usa `CI=true` para pular testes sensíveis a tempo ou que dependam do índice real da máquina; localmente eles rodam normalmente.
