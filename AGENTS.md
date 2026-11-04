# Repository Workflow

These instructions apply to the entire repository.

## Direct-to-master development

- This project does not use a pull request workflow.
- Make all requested changes directly on the `master` branch. Do not create feature branches or submit pull requests.
- Before editing, switch to `master` and synchronize it with the `master` branch of every configured remote using fast-forward-only pulls.
- Run the relevant tests and checks before committing.
- Commit completed changes on `master` and push them directly to the `master` branch of every configured remote.
- Never force-push or rewrite published history unless the user explicitly requests it.
- Preserve unrelated user changes already present in the working tree.

## Public repository hygiene

- Use a public commit identity, preferably the contributor's GitHub noreply email. Do not use an employer email by default.
- Never publish local credentials, recordings, diagnostic dumps, Git backups, or private recovery branches.
- Do not mirror refs or automatically share AI notes with the public remote. Private recovery branches must remain on their designated private remote.
