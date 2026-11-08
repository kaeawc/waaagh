# bashcov settings for dev/coverage.sh: count the scripts, not the suites or their helpers.
require 'simplecov'
SimpleCov.coverage_dir 'coverage'
SimpleCov.formatter = SimpleCov::Formatter::SimpleFormatter
filter = SimpleCov.respond_to?(:skip) ? :skip : :add_filter
[%r{\.bats$}, %r{_helper\.bash$}, %r{/dev/}, %r{/\.git/}].each { |re| SimpleCov.public_send(filter, re) }
