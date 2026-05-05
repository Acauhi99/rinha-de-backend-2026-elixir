# Issue tracker: GitHub

Issues e PRDs deste repo vivem como GitHub Issues. Usar `gh` CLI para operações.

## Convenções

- Criar issue: `gh issue create --title "..." --body "..."`
- Ler issue: `gh issue view <numero> --comments`
- Listar issues: `gh issue list --state open --json number,title,body,labels,comments`
- Comentar issue: `gh issue comment <numero> --body "..."`
- Adicionar/remover labels: `gh issue edit <numero> --add-label "..."` / `--remove-label "..."`
- Fechar issue: `gh issue close <numero> --comment "..."`

Repo inferido de `git remote -v` automaticamente pelo `gh` quando comando roda dentro clone.

## Quando skill disser "publicar no issue tracker"

Criar GitHub issue.

## Quando skill disser "buscar ticket relevante"

Rodar `gh issue view <numero> --comments`.
