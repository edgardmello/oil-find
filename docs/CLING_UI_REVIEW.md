# Cling → Oil Find: revisão de interface

Análise realizada em 11/11/2026 sobre `/Applications/Cling.app`, versão 3.5.1 (`com.lowtechguys.Cling`). O objetivo é melhorar a interface AppKit do Oil Find, mantendo o motor de busca e as convenções desta branch.

## Evidências e limites

- REA 6.3.0, `inspect-artifact /Applications/Cling.app`: inventário concluído, 410 nós e 414 relações. Evidence ID: `ev_ff2ad9e386a7a91f0250225ea1d227e3240dc9c4edc7e91669bd18e4024b49f6`; inventário interno: `ev_7f87ffcd697816510a897157f4eb7028440e7e893fa0b139a1bad0f37146001e`. SHA-256 da árvore: `914feb425c08e5bcdca8297cad6a27f974b9954b2ba75112137d7860ac76cf4d`.
- REA `inspect-plist`: Evidence ID `ev_6d45b989b7f1f497cc62cc03ec2a70e3d9c44d3f72a5e2ab17e6d50106cdbac9`. Confirma identidade, versão, esquema `cling:` e declaração de descoberta local `_cling._tcp`. Declarações não comprovam funcionamento de busca remota.
- REA `inspect-macho`: Evidence ID `ev_244eff6425e4d4619f22bd1e23f5eeaebbcd498fa3ba9ef1f8cedc08c747eff4`. Binário universal x86_64/arm64; fatia analisada arm64, macOS mínimo 14.0, dependências AppKit, SwiftUI, AVKit e QuickLookUI. Bibliotecas presentes não comprovam o uso em cada fluxo da interface. SHA-256 do executável: `158f4485169775364c10ba50b0d944c990768383d3aa0775c33aa4d33076c8d6`.
- Observação em execução com Computer Use: árvore de acessibilidade e captura da janela principal. A observação visual é independente do inventário estático do REA.
- O REA está registrado, mas suas ferramentas MCP não estão expostas nesta sessão. Usou-se a CLI. `doctor` não encontrou Hopper nem um Ghidra configurado para o REA. As primeiras tentativas de `inspect-macho` e `inspect-plist` falharam no subprocesso `file` dentro do sandbox; ambas concluíram ao permitir a execução das ferramentas locais. Não houve descompilação, recuperação de código ou comprovação dos algoritmos internos.
- `observe-native-ui` da CLI exigiu PID e ID da janela; sem esses campos a tentativa não produziu evidência. A observação da interface foi feita pelo Computer Use.

## Recursos observados

| Pergunta | Observação | Cobertura |
| --- | --- | --- |
| Como a busca é apresentada? | Campo de busca com controles de busca exata, Everything, histórico e referência de sintaxe. | Controles observados; algoritmos e histórico não exercitados. |
| Como os resultados são organizados? | Tabela com Name, Path, Size e Date Modified; Stash separado acima dos resultados. | Estrutura observada em execução. |
| Como a prévia mantém contexto? | Painel lateral com nome, localização e metadados do arquivo selecionado; a janela observada exibia prévia de vídeo. | Uma seleção observada; cobertura de formatos desconhecida. |
| Como os filtros são descobertos? | Grupos Search only e Search inside com ícones, rótulos e atalhos; botão Quick Filters junto da busca. | Controles observados. Quick Filters abriu aviso de licença Pro. |
| Quais modos de janela existem? | Controles Pin e de alternância para floating bar visíveis. | Disponibilidade observada; alternância não exercitada. |
| Quais recursos adicionais estão no pacote? | Scripts de ZIP, comparação/diff, impressão, listagem e uso de disco; workflow Alfred e recursos web. | Presença estática; execução e integração não verificadas. |

## Decisões implementadas no Oil Find

As mudanças abaixo são decisões próprias de design, motivadas pelos recursos observados e por problemas encontrados no código do Oil Find. Não foram copiados código nem recursos gráficos do Cling.

- **Prévia com contexto:** cabeçalho com nome e caminho, botão de fechar com rótulo acessível e resumo de tamanho/tipo e data. A seleção continua sob controle do SearchViewController.
- **Prioridade ao nome:** a lista de duas linhas remove as colunas secundárias quando sua largura não comporta nome e metadados confortavelmente. O inspector mantém o resumo do arquivo; a tabela compacta mantém suas colunas.
- **Controles reconhecíveis:** os menus da barra têm superfície discreta e feedback de estado; títulos respeitam os limites do botão. Categorias que não cabem passam para um menu nativo que conserva todas as opções.
- **Teclado e acessibilidade:** categorias expõem seu estado e atalhos; os atalhos do rodapé cedem espaço gradualmente; limpar a busca tem nome acessível, alvo maior e posição separada do controle de expansão.

Não foram adicionados busca remota, novos formatos de índice, dependências, assinatura comercial nem serviços de rede. O modo clássico e a busca em barra continuam disponíveis.

## Validação

A interface é validada pela entrada de debug `--snapshot`, com índice temporário de arquivos de exemplo, em temas claro e escuro, lista normal/compacta, prévia lateral e busca em barra. Artefatos e índices de teste ficam fora do repositório. Resultados:

- Build debug: aprovado, inclusive empacotamento e verificação de assinatura via `scripts/build-app.sh --debug`. Aplicativo gerado em `build/debug/Oil Find.app`.
- Build release: aprovado com SwiftPM e scratch path temporário.
- 26 testes focados em aparência, edição, filtros, seleção, conteúdo suplementar e configurações: aprovados com acesso aos serviços locais do macOS.
- `python3 Tests/Scripts/test_open_core.py`: 2 testes aprovados.
- Suíte completa de interface: 134 testes executados, 1 ignorado e 11 asserções falharam em 5 testes. Os mesmos 5 testes produziram as mesmas 11 falhas no código original de HEAD, copiado para uma árvore temporária sem as mudanças desta entrega. Os casos são os dois watchers de `AITopicTests`, o watcher de `WorkBuddyTopicTests`, `M26UITests.testQuickLookKeepsSearchFocusCaretAndIgnoresHeldKeys` e `MultipleSelectionTests.testShiftArrowsAndSelectAllBuildAMultipleSelectionThatDragsAsMove`. Essas falhas preexistentes permanecem abertas.
- Capturas conferidas: temas claro/escuro, prévia com Quick Look de arquivo de texto, listas normal/compacta, modo clássico e barra expandida. O sandbox impedia identificar tipos de arquivo e carregar a prévia; a captura com serviços locais disponíveis confirmou a renderização do conteúdo.
- `git diff --check`: aprovado.

Evidências completas da CLI foram conservadas fora do repositório, no diretório de visualizações desta sessão (`cling-evidence/artifact.json`, `macho.json`, `plist.json`).
