require 'json'
require 'net/http'
module Beaker
  class Icm < Beaker::Hypervisor

    SSH_EXCEPTIONS = [
      SocketError,
    ]

    APPLIANCE_IDS = {     #TODO Needs to include all valid appliances (templates)
      :sles11 => "11608"  #TODO Needs to validate platform against IDs for support
    }

    class RestartError < RuntimeError; end
    class FailError < RuntimeError; end

    # PUBLIC HYPERVISOR INTERFACE METHODS

    def initialize(new_hosts, options)
      @options = options
      @logger = options[:logger]
      @hosts = new_hosts

      set_icm_specific_options
    end

    def validate
      # noop
    end

    def configure
      # noop
    end

    def proxy_package_manager
      # noop
    end

    def provision
      last_wait, wait = 0, 1
      @waited = 0 #the amount of time we've spent waiting for this host to provision
      tries = 0
      begin
        @logger.trace( "Try #{tries+1}" )
        workload_create
        # workload_show
        workload_kickoff
        workload_wait_until_complete
        workload_get_host_ip
      rescue Icm::RestartError => e
        @logger.debug "Failed Icm provision: #{e.class} : #{e.message}"
        tries += 1
        if @waited <= @options[:timeout].to_i
          @logger.debug("Retrying provision for Icm host after waiting #{wait} second(s)")
          tries += 1
          @logger.trace( "cleaning up failed workload..." )
          workload_delete_failures
          sleep wait
          @waited += wait
          last_wait, wait = wait, last_wait + wait
          @logger.trace( "retrying..." )
          retry
        end
        report_and_raise( @logger, e, 'Icm.provision' )
      rescue Icm::FailError => e
        @logger.debug "Failed Icm provision: #{e.class} : #{e.message}"
        cleanup
        report_and_raise( @logger, e, 'Icm.provision' )
      end
      @logger.debug( "Icm.provision finished in #{@waited} seconds" )
    end

    def cleanup
      workload_delete_all
    end


    private # PRIVATE ICM-SPECIFIC FUNCTIONALITY


    # validates & sets beaker options necessary for ICM hypervisor
    #
    # @raise FailError if options are not passed correctly
    # @return nil
    def set_icm_specific_options
      required_options = [:icm_api_user, :icm_api_password, :icm_api_project_id]
      required_options << :icm_api_workloads_url
      required_options.each do |needed_option|
        unless @options[needed_option]
          message = "global :#{needed_option} setting required for ICM hypervisor"
          doc_url = "https://github.com/puppetlabs/beaker/tree/master/docs/hypervisors/icm.md"
          message << "\nCheck #{doc_url} for more info on required settings.\n"
          raise( FailError, message )
        end
      end
      @api_user           = @options[:icm_api_user]
      @api_password       = @options[:icm_api_password]
      @project_id         = @options[:icm_api_project_id]
      @api_workloads_url  = @options[:icm_api_workloads_url]

      @workloads = {}
      timestamp = @options[:timestamp].strftime("%F_%H_%M_%S_%N")
      random_suffix = rand(10 ** 10).to_s.rjust(10,'0') # 10 digit random number string
      # prefix because we only specify matching part, can be added on during provisioning
      @name_prefix = "beaker_#{timestamp}_#{random_suffix}"
    end

    # creates ICM workload. This establishes the workload
    # but doesn't run it. This needs to be followed up by
    # {#workload_kickoff} to actually provision a host
    #
    # @return [String] workload ID. This will be needed to
    #   further interact with the workload
    def workload_create
      icm_url = @api_workloads_url
      icm_payload = { 'appliance' => APPLIANCE_IDS[:sles11] }
      @hosts.each do |host|
        if @workloads.has_key?( host )
          @logger.trace( "Host #{host} already has a started workload, skipping workload_create" )
          next
        end
        icm_response_hash = icm_request_hash( icm_url, icm_payload, Net::HTTP::Post )
        if icm_response_hash[:id] == 'CYX1417E'
          message = icm_response_hash['message']
          message << "\n#{icm_response_hash['response']}"
          message << "\n#{icm_response_hash['technicalData']}"
          raise( RestartError, message )
        end
        @logger.trace( "Response hash: #{icm_response_hash}" )
        @workloads[host] = {
          :id => icm_response_hash['id'],
          :kicked => false,
          :provisioned => false,
          :error_message => nil,
          :ip_assigned => false,
        }
        @logger.trace( "Workload #{@workloads[host][:id]} created for host #{host}" )
      end
    end

    # kicks off a created workload. This should only be
    # run on workloads that are already created, it won't
    # create one for you
    #
    # @parm [String] workload_id ID of the workload we're
    #   going to kick off
    def workload_kickoff

      @workloads.each do |host, workload_details|
        if workload_details[:kicked]
          @logger.trace( "Host #{host} has kicked workload #{workload_details[:id]} already, skipping workload_kickoff" )
          next
        end
        icm_url = "#{@api_workloads_url}/#{workload_details[:id]}"
        icm_payload = {
          'instances' => 1,
          'project' => @project_id,
          'name' => @name_prefix,
          'state' => 'EXECUTING'
        }
        icm_response = icm_request( icm_url, icm_payload, Net::HTTP::Put )
        @logger.trace( "Response json: #{icm_response.body}" )
        if icm_response.body =~ /SUCCESS: Instance '#{workload_details[:id]}' initiated/
          icm_response_parsed = icm_response.body
        else
          icm_response_parsed = JSON.parse(icm_response.body)
          if icm_response_parsed['id'] == 'CYX4595E'
            @logger.trace( "failure json: #{icm_response.body}" )
            # this error is specific to hitting the resource quota
            # in this case, we should actually fail provisioning
            message = icm_response_parsed['message']
            message << "\n#{icm_response_parsed['explanation']}"
            raise( FailError, message )
          end
        end
      end

      # @workloads.each do |host, workload_details|
      #   if workload_details[:error_message]
      #     raise( RestartError, workload_details[:error_message] )
      #   end
      # end
    end

    def workload_show
      @logger.trace( "workload_show revealing all workloads..." )
      @workloads.each do |host, workload_details|
        icm_url = "#{@api_workloads_url}/#{workload_details[:id]}"
        icm_payload = { 'state' => 'Show' }
        icm_response_hash = icm_request_hash( icm_url, icm_payload, Net::HTTP::Put )
        @logger.trace( "  #{workload_details[:id]} Response hash: #{icm_response_hash}" )
        if icm_response_hash['id'] == 'CYX4734E'
          # specific error about calling show before an instance is "banned".
          # TODO I have no idea what it means to be banned right now....
          message = icm_response_hash['message']
          message << "\n#{icm_response_hash['explanation']}"
          raise( FailError, message )
        end
      end
    end

    WORKLOAD_SUCCESS_STATES = %w( OK RUNNING )
    WORKLOAD_FAILURE_STATES = %w( ERROR ATTEMPTED )
    WORKLOAD_PROGRESS_STATES = %w( EXECUTING COMPLETED )

    # polls ICM API until workload status is "ok"
    def workload_wait_until_complete
      last_wait_error, wait_error = 0, 1
      tries = 0
      begin
        # we don't expect this to resolve itself in the first minute,
        # so we'll start down the progression a ways
        last_wait_retry, wait_retry = 34, 55
        while true do
          # @logger.trace( "try #{tries + 1}:" )
          @workloads.each do |host, workload_details|
            if workload_details[:provisioned]
              @logger.trace( "Host #{host} workload #{workload_details[:id]} provisioned already, skipping status check" )
              next
            end

            icm_url = "#{@api_workloads_url}/#{workload_details[:id]}"
            icm_response_hash = icm_request_hash( icm_url, {}, Net::HTTP::Get )
            workload_status = icm_response_hash['state']['id']
            status_message = "  Status: #{workload_status}"
            @logger.trace( "  Response json: #{icm_response_hash}" )
            if WORKLOAD_SUCCESS_STATES.include?( workload_status )
              @logger.debug( "#{status_message}, everything OK, breaking!" )
              workload_details[:provisioned] = true
            elsif WORKLOAD_FAILURE_STATES.include?( workload_status )
              @logger.debug( "  Response json: #{icm_response_hash}" )
              workload_details[:error_message] = "#{status_message}, workload failed, restart needed"
            elsif WORKLOAD_PROGRESS_STATES.include?( workload_status )
              @logger.debug( "#{status_message}, workload in progress. Continuing" )
            else
              @logger.debug( "  Response json: #{icm_response_hash}" )
              workload_details[:error_message] = "#{status_message}, workload state not accounted for"
            end
          end

          all_hosts_provisioned = true
          @workloads.each do |host, workload_details|
            all_hosts_provisioned &= workload_details[:provisioned]
            raise( RestartError, workload_details[:error_message] ) if workload_details[:error_message]
          end
          break if all_hosts_provisioned

          if @waited <= @options[:timeout].to_i
            @logger.debug( "Retrying Icm status check-1 after waiting #{wait_retry} second(s)" )
            tries += 1
            sleep wait_retry
            @waited += wait_retry
            last_wait_retry, wait_retry = wait_retry, last_wait_retry + wait_retry
          end
        end
        @logger.trace( 'finished status checking' )

      rescue *SSH_EXCEPTIONS => e
        @logger.debug "Failed Icm status check: #{e.class} : #{e.message}"
        if @waited <= @options[:timeout].to_i
          @logger.debug( "Retrying status check for Icm host(s) after waiting #{wait_error} second(s)" )
          tries += 1
          sleep wait_error
          @waited += wait_error
          last_wait_error, wait_error = wait_error, last_wait_error + wait_error
          retry
        end
        report_and_raise( @logger, e, 'Vmpooler.provision' )
      end
    end

    def workload_delete_failures
      @workloads.each do |host, workload_details|
        workload_delete( host ) if workload_details[:error_message]
      end
    end

    def workload_delete_all
      @workloads.each do |host, workload_details|
        workload_delete( host )
      end
    end

    def workload_delete( host )
      workload_id = @workloads[host][:id]

      icm_url = "#{@api_workloads_url}/#{workload_id}"
      icm_payload = { 'hard' => true }
      icm_response = icm_request( icm_url, icm_payload, Net::HTTP::Delete )
      @logger.trace( "Delete response: '#{icm_response.body}'" )
      @workloads.delete( host )
    end

    def workload_get_host_ip
      servers_found = false
      (1...10).each do |try|
        @workloads.each do |host, workload_details|
          if workload_details[:ip_assigned]
            @logger.trace( "Host #{host} workload #{workload_details[:id]} ip assigned already, skipping status check" )
            next
          end
          @logger.trace( "icm.workload_get_host_ip, ##{try}" )
          icm_url = "#{@api_workloads_url}/#{workload_details[:id]}/virtualServers"
          icm_response_hash = icm_request_hash( icm_url, {}, Net::HTTP::Get )
          @logger.trace( "  Response hash: #{icm_response_hash}" )
          servers_found = !icm_response_hash.empty?
          if servers_found
            servers_found = !icm_response_hash['virtualServers'].empty?
          end
          if servers_found
            host['vmhostname'] = icm_response_hash['virtualServers'][0]['ip']
            workload_details[:ip_assigned] = true
            @logger.trace( "  - assigned IP: #{host}: #{host['vmhostname']}" )
          end
        end

        all_ips_assigned = true
        @workloads.each do |host, workload_details|
          unless workload_details[:ip_assigned]
            all_ips_assigned = false
            break
          end
        end
        break if all_ips_assigned
      end

      unless servers_found
        error = RestartError.new( 'could not get host IPs' )
        report_and_raise(@logger, error, 'Icm.workload_get_host_ip')
      end

      # @logger.trace( "  Host IPs:" )
      # icm_response_hash['virtualServers'].each_with_index do |server_hash, index|
      #   @logger.trace( "  - server hash: #{server_hash}" )
      #   @hosts[index]['vmhostname'] = server_hash['ip']
      #   @logger.trace( "    - #{@hosts[index]}: #{@hosts[index]['vmhostname']}")
      # end
    end

    # Helper that will send back the parsed response, rather
    # than just the response object itself
    #
    # @param [String] url URL to call
    # @param [Hash] payload HTTP request payload
    # @param [Net::HTTP] http_verb HTTP verb of the request
    #
    # @return [Hash] HTTP response parsed from JSON to a
    #   ruby hash object
    def icm_request_hash( url, payload, http_verb )
      icm_response = icm_request( url, payload, http_verb )
      JSON.parse( icm_response.body )
    end

    def icm_request( url, payload, http_verb )
      uri = URI.parse( url )

      http = Net::HTTP.new( uri.host, uri.port )
      http.use_ssl = ( uri.scheme == 'https' )
      request = http_verb.new( uri.request_uri )
      request.basic_auth( @api_user, @api_password )
      request['Content-Type'] = 'application/json'

      request_payload_json = payload.to_json
      @logger.trace( "#{http_verb} #{url}: #{request_payload_json}" )
      # @logger.trace( "Request payload json: #{request_payload_json}" )
      request.body = request_payload_json

      tries = 1
      begin
        http.request(request)
      rescue Errno::ETIMEDOUT => e
        @logger.trace( "Request ##{tries} timed out. ")
        tries += 1
        if tries < 11
          @logger.trace( "Retrying" )
          retry
        else
          @logger.trace( "Bailing as a failure" )
          report_and_raise(@logger, e, 'Icm.icm_request')
        end
      end
    end
  end
end
