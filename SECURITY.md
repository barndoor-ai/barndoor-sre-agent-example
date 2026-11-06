# Security policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue or pull
request. Use GitHub's private reporting: open the repository's **Security**
tab and click **Report a vulnerability**. Only the maintainers can see the
report.

Include what you found, how to reproduce it, and which example (01, 02 or 03)
or file it affects. We will acknowledge the report and keep you updated while
we work on a fix.

Vulnerabilities in the Barndoor platform itself, rather than in this example,
can be reported the same way; we will route them to the right team.

## Credentials

Every example handles live credentials: the agent's Barndoor client secret,
an LLM gateway key, a Terraform credential, and in some setups an upstream
Anthropic key. They belong in `.env` and `*.tfvars`, which are gitignored.

If you commit one by mistake, **rotate it first**, then remove it from history.
Removing a commit does not revoke a key that has already been pushed.

- Barndoor agent client secret: rotate from the agent's page under **AI Agents**.
- LLM gateway key: delete it under the agent's **Manage keys**, then create a new one.
- Terraform credential: revoke and recreate it under **Settings → API Tokens**.
- Anthropic key: revoke it in the Anthropic Console.
