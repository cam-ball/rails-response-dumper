# frozen_string_literal: true

require_relative 'defined'

module RailsResponseDumper
  class Runner
    def run_dumps
      dumps_dir = Rails.root.join('dumps')
      FileUtils.rm_rf dumps_dir
      FileUtils.mkdir_p dumps_dir

      Dir[Rails.root.join('dumpers/**/*.rb')].each { |f| require f }

      errors = []

      RailsResponseDumper::Defined.dumpers.each do |defined|
        defined.blocks.each do |dump_block|
          defined.reset_models!
          dumper = defined.klass.new
          dumper.mock_setup
          begin
            rollback_after do
              dumper.instance_eval(&defined.before_block) if defined.before_block
              begin
                dumper.instance_eval(&dump_block.block)
              ensure
                dumper.instance_eval(&defined.after_block) if defined.after_block
              end
            end
          ensure
            dumper.mock_teardown
          end

          unless dumper.responses.count == dump_block.expected_status_codes.count
            raise <<~ERROR.squish
              #{dumper.responses.count} responses
              (expected #{dump_block.expected_status_codes.count})
            ERROR
          end

          klass_path = defined.name.underscore
          dumper_dir = "#{dumps_dir}/#{klass_path}/#{dump_block.name}"
          FileUtils.mkdir_p dumper_dir

          dumper.responses.each_with_index do |response, index|
            unless response.status == dump_block.expected_status_codes[index]
              raise <<~ERROR.squish
                unexpected status code #{response.status} #{response.status_message}
                (expected #{dump_block.expected_status_codes[index]})
              ERROR
            end

            request = response.request
            dump = {
              request: {
                method: request.method,
                url: request.url
              },
              response: {
                status: response.status,
                headers: response.headers,
                body: response.body
              }
            }
            File.write("#{dumper_dir}/#{index}.json", JSON.pretty_generate(dump))
          end

          print '.'
        rescue StandardError => e
          errors << {
            dumper_location: dump_block.block.source_location.join(':'),
            name: "#{defined.name}.#{dump_block.name}",
            message: e.exception.message,
            backtrace: e.cause&.backtrace || e.exception.backtrace
          }

          print 'F'
        end
      end

      puts
      return if errors.blank?

      errors.each do |error|
        print "#{error[:dumper_location]} #{error[:name]} received #{error[:message]}\n"
        print "#{error[:backtrace][0]}\n\n"
      end

      exit(false)
    end

    private

    def rollback_after
      if defined?(ActiveRecord::Base)
        ActiveRecord::Base.transaction do
          yield
          raise ActiveRecord::Rollback
        end
      else
        # ActiveRecord is not installed.
        yield
      end
    end
  end
end
