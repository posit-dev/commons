# Hospital events

This public example is generated synthetic data, not a supplied pin or records from real hospitals.

Each row is one recorded event. Counts describe the supplied records, not hospital incidence rates or hospital quality.

The dataset contains hospital names, event types, and severity labels only. It has no dates, patient identifiers, admission totals, or exposure denominators. Do not infer trends, patient risk, or causation.

Severity labels are Level 1, Level 2, and Level 3. Their clinical meaning and ordering are not defined in the supplied file; report them as categories without assigning clinical interpretations.

The approved summary and grouped-count tools count rows, with an optional exact hospital-name filter. Custom SQL uses the hospital source and the hospital_events table. Preserve the original column names hospitals_table, events_table, and severity_table.
