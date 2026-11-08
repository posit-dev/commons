if (!testthat::is_checking()) {
  local_env_file(env_file_path(), testthat::teardown_env())
}
