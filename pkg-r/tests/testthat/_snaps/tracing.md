# new_trajectory_tracing validates its inputs

    Code
      new_trajectory_tracing(TRUE, share_with = 1)
    Condition
      Error:
      ! `share_with` must be a character vector of Connect usernames.

# share_with warns and is ignored when log = FALSE

    Code
      .res <- new_trajectory_tracing(FALSE, share_with = "jdoe")
    Condition
      Warning:
      `share_with` only applies when `log = TRUE`; ignoring it.

# log = TRUE warns without the otel package

    Code
      .res <- new_trajectory_tracing(TRUE)
    Condition
      Warning:
      Trajectory logging requires the otel package.
      i Install otel (and otelsdk) to enable it.

# the content instrumentation warning reflects Connect's setting

    Code
      warn_if_content_instrumentation_disabled()
    Condition
      Warning:
      Trajectory logging is disabled by this Posit Connect server's configuration.
      i Ask your server administrator to set `OpenTelemetry.Enabled = true` and `OpenTelemetry.AllowContentInstrumentation = true` in the Connect configuration, then restart Connect.

# the content-capture deployment warning is limited to Connect

    Code
      warn_if_content_capture_not_deployed()
    Condition
      Warning:
      Trajectory logging requires additional deployment setup.
      i Include `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` in the `envVars` argument to `rsconnect::deployApp()`, then redeploy.

# log = TRUE warns when tracing stays disabled locally

    Code
      .res <- new_trajectory_tracing(TRUE)
    Condition
      Warning:
      Trajectory logging is enabled but OpenTelemetry tracing is not active.

# log = TRUE points at Content Observability on Connect

    Code
      .res <- new_trajectory_tracing(TRUE)
    Condition
      Warning:
      Trajectory logging is enabled but OpenTelemetry tracing is not active.
      i In this content's Settings > Monitoring > Traces panel on Posit Connect, select Enabled, then redeploy or restart the content.

# tracing disabled on Connect flips the observability setting on

    Code
      .res <- new_trajectory_tracing(TRUE)
    Condition
      Warning:
      Enabled Content Observability for this content, but this process started without it.
      i Trajectory logging will begin once the content restarts.

# an already-on observability setting warns about the restart

    Code
      .res <- new_trajectory_tracing(TRUE)
    Condition
      Warning:
      Content Observability is enabled for this content, but this process started without OpenTelemetry tracing.
      i Trajectory logging will begin once the content restarts.

# share_trajectory_access warns off Connect

    Code
      share_trajectory_access("jdoe")
    Condition
      Warning:
      `share_with` only applies when running on Posit Connect.
      i Ignoring `share_with`.

# share_trajectory_access warns rather than errors on failure

    Code
      share_trajectory_access("jdoe")
    Condition
      Warning:
      Could not share trajectory access with `share_with`.
      i no api key

