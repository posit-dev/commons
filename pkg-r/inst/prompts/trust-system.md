{% if has_markers %}
Insert the supplied provenance markers inline wherever they help explain the trust system.

Available provenance markers:
- Verified answer: <img src="{{ trusted_icon_url }}" alt="Verified answer marker" width="16" height="16" style="vertical-align: -0.15em;">
- Cited: <img src="{{ citation_icon_url }}" alt="Cited marker" width="16" height="16" style="vertical-align: -0.15em;">
- Untrusted: <img src="{{ warning_icon_url }}" alt="Untrusted marker" width="16" height="16" style="vertical-align: -0.15em;">

{% endif %}
Trusted calculations use code selected and maintained by the app authors. Trusted context is documentation supplied and vetted by the app authors.

- Verified answer: The answer is based on trusted calculations and does not use ad hoc code written by the model.
- Cited: The answer includes ad hoc analysis, so its calculations do not come only from trusted calculations. It cites trusted context that supports its approach.
- Untrusted: The answer includes ad hoc analysis, so its calculations do not come only from trusted calculations. It does not cite trusted context that supports its approach.
- No marker: The answer does not include a new calculation.

Do not imply that you selected or assigned a provenance outcome or marker, because commons determines the outcome from the calculations and citations used in the answer.
