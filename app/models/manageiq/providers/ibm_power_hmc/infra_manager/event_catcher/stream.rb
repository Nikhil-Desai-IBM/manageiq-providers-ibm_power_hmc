class ManageIQ::Providers::IbmPowerHmc::InfraManager::EventCatcher::Stream
  def initialize(ems, options = {})
    @ems = ems
    @last_activity = nil
    @stop_polling = false
    @options = options
  end

  def start
    @stop_polling = false
  end

  def stop
    @stop_polling = true
  end

  def poll(&block)
    @ems.with_provider_connection do |connection|
      # HMC waits 10 seconds before returning 204 if there is no event.
      until @stop_polling
        events = connection.next_events(false).select do |event|
          event.type.in?(["ADD_URI", "MODIFY_URI", "DELETE_URI"])
        end
        events.each(&block)
        sleep(@options[:poll_sleep]) if events.empty?
      end
    rescue IbmPowerHmc::Connection::HttpError => e
      $ibm_power_hmc_log.error("querying hmc events failed: #{e}")
      raise
    end
  end
end
