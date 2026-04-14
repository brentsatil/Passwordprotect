# Decisions Needed Before Implementation

Implementation is blocked until the business owner answers these. Each
decision changes either the file format, the deployment model, or the
scope of the tool, so getting them wrong is expensive.

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| 1 | **Key escrow** | (a) Admin recovery key on every file; (b) no escrow, forgotten password = lost file | (a) — the support cost of "I lost my password" without escrow is higher than the risk of custodying an admin key properly. |
| 2 | **Password model** | (a) Each user picks per-file; (b) shared team password; (c) per-department; (d) certificate-based | (a) + escrow for v1. Revisit (d) if adoption > 20 users. |
| 3 | **Delete original after protect** | Default on / default off / opt-in checkbox | Opt-in checkbox, default **off**. Safer. |
| 4 | **Bundle dependencies** | Bundle `qpdf.exe` + `7z.exe` in the MSI, or require pre-install | Bundle. Fewer moving parts for end users; procurement vets the MSI once. |
| 5 | **Deployment channel** | MSI via Intune/GPO / manual `install.ps1` / both | Both. MSI for production, `install.ps1` for the developer loop. |
| 6 | **Regulated data in scope?** | Yes (PHI/PCI/legal/HR) / No | If yes, **do not** use this tool for that data — use Purview / AIP. Put the scope boundary in the first-run notice. |
| 7 | **Automation scope for v1** | (a) Right-click + folder batch only; (b) also watched drop folder; (c) also scheduled bulk jobs | (a) for v1. (b) only after EDR whitelist is agreed with IT. |
| 8 | **Minimum password policy** | Length / complexity / blocked list | Min length 12, at least 3 of {lower, upper, digit, symbol}, reject top-10k common passwords. |
| 9 | **Output location** | Next to source / dedicated "protected" folder / both | Next to source by default, "Save as…" override in the prompt. |
| 10 | **Name on the right-click menu** | "Protect with password" / something branded | "Protect with password" — describes what it does. |

When these are answered, I'll cut the design in `ARCHITECTURE.md`, commit,
and start shipping code.
