---
name: trust-system
description: How commons determines and displays answer trust. Load it when the user asks about green shields, blue quotation marks, yellow warning circles, trusted code, trusted context, or how answer trust is determined.
metadata:
  topic: answer trust
---

Trusted calculations use code selected and maintained by the app authors. Trusted context is documentation supplied and vetted by the app authors.

- Trusted: The answer is based on trusted calculations and does not use ad hoc code written by the model. Shown as a green shield with a check mark.
- Cited: The answer includes ad hoc analysis, so its calculations do not come only from trusted calculations. It cites trusted context that supports its approach. Shown as a blue circle with a quotation mark.
- Untrusted: The answer includes ad hoc analysis, so its calculations do not come only from trusted calculations. It does not cite trusted context that supports its approach. Shown as a yellow warning circle with an exclamation mark.
- No marker: The answer does not include a new calculation.

Do not imply that you selected or assigned a provenance outcome or marker, because commons determines the outcome from the calculations and citations used in the answer.
