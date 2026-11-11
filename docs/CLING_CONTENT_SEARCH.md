# Busca de conteúdo do Cling com `[]`

Investigação do Cling 3.5.1 instalado, em 11/11/2026. Foram usados REA 6.3.0, Ghidra 12.2 e observação da referência de sintaxe na interface. Nenhuma funcionalidade do Oil Find foi modificada nesta etapa.

## Resultado

O Cling combina **consultas de conteúdo ao Spotlight** com **leitura direta de arquivos candidatos**. A rotina que constrói o predicado inclui uma condição especial para imagens. O caminho examinado não contém um pipeline próprio de OCR demonstrado.

### Sintaxe confirmada pela interface

| Consulta | Finalidade apresentada pelo Cling |
| --- | --- |
| `[client]` | Texto dentro do arquivo |
| `invoice [client]` | Combina busca de nome com conteúdo |
| `.pdf ["payment received"]` | Palavras nessa sequência |
| `.jpg [dog]` | Algo visto em uma imagem |
| `.pdf [invoice\|receipt]` | Uma alternativa ou outra no conteúdo |
| `invoice [!paid]` | Exclui arquivos que contêm o termo |
| `content:"payment received"` | Forma alternativa de busca de conteúdo |

A interface documenta busca de texto em arquivos e de elementos reconhecidos em imagens; a qualidade e a cobertura para palavras dentro de imagens não foram medidas nesta instalação.

## Fluxo recuperado no Ghidra

Os nomes `FUN_...` abaixo são identificadores do descompilador, não nomes originais do código-fonte.

1. **Combinação de condições — `0x100261af4`.** Recebe grupos de termos; une alternativas com ` || `, aplica `!(` aos grupos negativos e une grupos com ` && `. Chama `0x10026188c` para construir cada predicado de conteúdo.
2. **Predicado por termo — `0x10026188c`.** Monta condições com `kMDItemTextContent`, `kMDItemKeywords` e `kMDItemContentTypeTree == "public.image" && ** == ...`. O ramo de comparação literal envolve o termo com `*`; o outro chama a rotina de correspondência por palavra. O campo `**` consulta atributos indexados do Spotlight; o binário não entrega aqui pixels a um reconhecedor de imagem.
3. **Correspondência por palavra — `0x100253214`.** Para um termo sem espaços com menos de cinco caracteres, constrói duas condições: o termo e o termo acrescido de `s`. Para termos maiores, constrói o termo seguido de `*`. Os predicados usam os modificadores `cdw`. Essa regra coincide com a descrição de diagnóstico embutida no aplicativo: palavra inteira/plural para termos curtos, início de palavra para termos maiores, fora do modo exato.
4. **Execução no Spotlight — `0x1002620b0`.** Usa `MDQueryCreate`, `MDQuerySetMaxCount`, `MDQuerySetSearchScope`, `MDQueryExecute` e `MDQueryGetResultAtIndex`; extrai os caminhos por `MDItemCopyAttribute(..., kMDItemPath)`. Há cancelamento e espera limitada a aproximadamente dez segundos.
5. **Coordenação — `0x100246508`.** Chama o montador e o executor acima, combina candidatos e executa workers com `DispatchQueue.concurrentPerform`. Os logs do próprio caminho distinguem resultados do Spotlight de arquivos lidos diretamente. O worker observado é `0x10025741c`, alcançado pela closure `0x100269080`.
6. **Leitura direta — `0x100254374`.** O worker chama esta rotina, que usa `open`, `fstat`, `pread` e `close`. Verifica arquivo regular e tamanho entre 1 byte e 256 MiB, testa presença de NUL nos primeiros até 8 KiB (com exceção explícita para `bplist`) e percorre conteúdo em blocos. Há leitura inicial de até 64 KiB, blocos posteriores de até 1 MiB e retenção de uma cauda baseada no maior termo, evitando perder correspondências entre blocos. O tratamento de PDF segue um ramo separado; sua extração não foi completamente rastreada.

### Exemplo conceitual do predicado

Abaixo está uma simplificação legível, não uma transcrição exata de toda consulta produzida pelo aplicativo:

```text
(texto indexado corresponde ao termo
 OR palavras-chave indexadas correspondem ao termo
 OR (tipo é imagem AND atributos indexados correspondem ao termo))
```

`[a|b]` combina dois desses predicados com OR; `[!a]` nega o grupo. Filtros de nome, pasta, tipo e outras condições entram na coordenação da busca.

## Imagens, OCR e reconhecimento de objetos

**Confirmado:** o construtor inclui `public.image` e `**` na consulta ao Spotlight. O executável importa as APIs `MDQuery*`/`MDItem*`, e o fluxo recuperado as chama.

**Observação limitada:** foram examinados 4.808 registros de importação do executável no Evidence do REA. Não apareceram imports diretos com os nomes `VNRecogn...`, `VNClass...` ou `RecognizeText`. Isso não prova ausência absoluta de OCR: carregamento dinâmico, frameworks intermediários ou serviços do macOS podem realizar processamento que não aparece nessa lista.

**Conclusão:** no caminho rastreado, o Cling delega a recuperação de resultados de imagens aos dados que o Spotlight disponibiliza. Não há evidência suficiente para afirmar que ele executa OCR próprio ou um modelo próprio de visão ao receber `[]`, nem para identificar o mecanismo interno de reconhecimento do Spotlight. Resultados dependem do que o macOS indexou.

## Limites e comportamento em execução

- A referência de sintaxe foi observada no aplicativo em execução.
- A ajuda oficial de `ClingCLI search` informa que `--read-all` inclui discos lentos/rede e todos os candidatos, em vez dos primeiros 2.000, para consultas `[texto]`. Isso é documentação do aplicativo; não foi realizado um benchmark dessa opção.
- Uma chamada `ClingCLI why` com `[preview]`, restrita a um arquivo temporário de exemplo, retornou que busca de conteúdo exige **Cling Pro**. Portanto, a operação completa sobre texto/imagem não foi validada nesta instalação. A verificação da licença permaneceu intacta.
- O Ghidra 12.2 estava instalado, mas não havia instância GUI conectada. O adaptador do REA 6.3.0 rejeitou essa versão por aceitar apenas 12.1.x e também exigiu uma fatia Mach-O única. Usou-se o REA para inventário/imports e o Ghidra diretamente em uma cópia arm64 extraída com `lipo`.
- A primeira autoanálise atingiu o limite de 240 segundos e registrou avisos de tipos Objective-C e de descompilação. As funções citadas foram posteriormente recuperadas em passes focados; não se afirma recuperação completa do aplicativo. Pseudocódigo Swift tem tipos e parâmetros inferidos, devendo ser lido junto às instruções e strings.

## Identidade e evidências

- Binário original: `/Applications/Cling.app/Contents/MacOS/Cling`.
- SHA-256 original: `158f4485169775364c10ba50b0d944c990768383d3aa0775c33aa4d33076c8d6`.
- SHA-256 da fatia arm64 analisada: `efd32e08abd276962f79d10857b52128a2bf2fc1644ab203dd51183b2964fa15`.
- Evidence REA dos imports e Mach-O: `ev_244eff6425e4d4619f22bd1e23f5eeaebbcd498fa3ba9ef1f8cedc08c747eff4`.
- Linguagem Ghidra: `AARCH64:LE:64:AppleSilicon`.
- Dumps de pseudocódigo, referências ARM64, scripts e logs foram conservados fora do repositório, em `cling-content-evidence` no diretório de visualizações desta sessão. `manifest.json` registra versões, hashes e limites; `content-functions.txt`, `content-details.txt` e `content-fileio.txt` sustentam os passos acima.

## Aplicação ao Oil Find

A sintaxe entre colchetes pode ser implementada no parser como grupos de conteúdo separados das condições de nome. Para reproduzir o comportamento de recuperação observado no Cling, seria preciso integrar candidatos do Spotlight e leitura direta cancelável. Para oferecer OCR próprio independente da cobertura do Spotlight, seria necessário um pipeline distinto; essa capacidade não deve ser atribuída ao Cling apenas com as evidências atuais. Esta etapa documenta a investigação e não implementa essas mudanças.
