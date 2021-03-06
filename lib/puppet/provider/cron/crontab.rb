require 'puppet/provider/parsedfile'

tab = case Facter.value(:operatingsystem)
    when "Solaris"; suntab
    else
        :crontab
    end


Puppet::Type.type(:cron).provide(:crontab,
    :parent => Puppet::Provider::ParsedFile,
    :default_target => ENV["USER"] || "root",
    :filetype => tab
) do
    commands :crontab => "crontab"

    text_line :comment, :match => %r{^#}, :post_parse => proc { |record|
        if record[:line] =~ /Puppet Name: (.+)\s*$/
            record[:name] = $1
        end
    }

    text_line :blank, :match => %r{^\s*$}

    text_line :environment, :match => %r{^\w+=}

    record_line :freebsd_special, :fields => %w{special command},
        :match => %r{^@(\w+)\s+(.+)$}, :pre_gen => proc { |record|
            record[:special] = "@" + record[:special]
        }

    crontab = record_line :crontab, :fields => %w{minute hour monthday month weekday command},
        :match => %r{^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)$},
        :optional => %w{minute hour weekday month monthday}, :absent => "*"

    class << crontab
        def numeric_fields
            fields - [:command]
        end
        # Do some post-processing of the parsed record.  Basically just
        # split the numeric fields on ','.
        def post_parse(record)
            numeric_fields.each do |field|
                if val = record[field] and val != :absent
                    record[field] = record[field].split(",")
                end
            end
        end

        # Join the fields back up based on ','.
        def pre_gen(record)
            numeric_fields.each do |field|
                if vals = record[field] and vals.is_a?(Array)
                    record[field] = vals.join(",")
                end
            end
        end


        # Add name and environments as necessary.
        def to_line(record)
            str = ""
            if record[:name]
                str = "# Puppet Name: %s\n" % record[:name]
            end
            if record[:environment] and record[:environment] != :absent and record[:environment] != [:absent]
                record[:environment].each do |env|
                    str += env + "\n"
                end
            end

            if record[:special]
                str += "@%s %s" % [record[:special], record[:command]]
            else
                str += join(record)
            end
            str
        end
    end


    # Return the header placed at the top of each generated file, warning
    # users that modifying this file manually is probably a bad idea.
    def self.header
%{# HEADER: This file was autogenerated at #{Time.now} by puppet.
# HEADER: While it can still be managed manually, it is definitely not recommended.
# HEADER: Note particularly that the comments starting with 'Puppet Name' should
# HEADER: not be deleted, as doing so could cause duplicate cron jobs.\n}
    end

    # See if we can match the record against an existing cron job.
    def self.match(record, resources)
        resources.each do |name, resource|
            # Match the command first, since it's the most important one.
            next unless record[:target] == resource.value(:target)
            next unless record[:command] == resource.value(:command)

            # Then check the @special stuff
            if record[:special]
                next unless resource.value(:special) == record[:special]
            end

            # Then the normal fields.
            matched = true
            record_type(record[:record_type]).fields().each do |field|
                next if field == :command
                next if field == :special
                if record[field] and ! resource.value(field)
                    #Puppet.info "Cron is missing %s: %s and %s" %
                    #    [field, record[field].inspect, resource.value(field).inspect]
                    matched = false
                    break
                end

                if ! record[field] and resource.value(field)
                    #Puppet.info "Hash is missing %s: %s and %s" %
                    #    [field, resource.value(field).inspect, record[field].inspect]
                    matched = false
                    break
                end

                # Yay differing definitions of absent.
                next if (record[field] == :absent and resource.value(field) == "*")

                # Everything should be in the form of arrays, not the normal text.
                next if (record[field] == resource.value(field))
                #Puppet.info "Did not match %s: %s vs %s" %
                #    [field, resource.value(field).inspect, record[field].inspect]
                matched = false
                break
            end
            return resource if matched
        end

        return false
    end

    # Collapse name and env records.
    def self.prefetch_hook(records)
        name = nil
        envs = nil
        result = records.each { |record|
            case record[:record_type]
            when :comment
                if record[:name]
                    name = record[:name]
                    record[:skip] = true

                    # Start collecting env values
                    envs = []
                end
            when :environment
                # If we're collecting env values (meaning we're in a named cronjob),
                # store the line and skip the record.
                if envs
                    envs << record[:line]
                    record[:skip] = true
                end
            when :blank
                # nothing
            else
                if name
                    record[:name] = name
                    name = nil
                end
                if envs.nil? or envs.empty?
                    record[:environment] = :absent
                else
                    # Collect all of the environment lines, and mark the records to be skipped,
                    # since their data is included in our crontab record.
                    record[:environment] = envs

                    # And turn off env collection again
                    envs = nil
                end
            end
        }.reject { |record| record[:skip] }
        result
    end

    def self.to_file(records)
        text = super
        # Apparently Freebsd will "helpfully" add a new TZ line to every
        # single cron line, but not in all cases (e.g., it doesn't do it
        # on my machine).  This is my attempt to fix it so the TZ lines don't
        # multiply.
        if text =~ /(^TZ=.+\n)/
            tz = $1
            text.sub!(tz, '')
            text = tz + text
        end
        return text
    end

    def user=(user)
        @property_hash[:user] = user
        @property_hash[:target] = user
    end

    def user
        @property_hash[:user] || @property_hash[:target]
    end
end

