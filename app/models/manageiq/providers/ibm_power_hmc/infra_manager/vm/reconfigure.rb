module ManageIQ::Providers::IbmPowerHmc::InfraManager::Vm::Reconfigure
  def reconfigurable?
    host_hmc_managed
  end

  def max_total_vcpus
    # 64 is based on the CEC's CurrentMaximumVirtualProcessorsPerAIXOrLinuxPartition and
    # CurrentMaximumVirtualProcessorsPerVirtualIOServerPartition settings.
    # This can be further reduced by the partition's MaximumVirtualProcessors setting.
    host && try(:processor_share_type) == "dedicated" ? host.cpu_total_cores : 64
  end

  def max_vcpus
    max_total_vcpus
  end

  # Returns the allowed vcpu range for this partition.
  # Consumed by the UI controller when supports?(:reconfigure_vcpus) is true.
  def reconfigure_vcpu_limits
    {
      :min => 1,
      :max => max_total_vcpus
    }
  end

  # Returns the current virtual processor count to pre-populate the reconfigure form.
  # For shared partitions, cpu_total_cores stores the virtual processor count (vprocs).
  def current_vcpu_count
    cpu_total_cores.to_i
  end

  def max_cpu_cores_per_socket(_total_vcpus = nil)
    1
  end

  def max_memory_mb
    host ? host.hardware.memory_mb : 1_024
  end

  def build_config_spec(options)
    $ibm_power_hmc_log.debug("building spec for #{options}")

    lpar = ext_management_system.with_provider_connection { |connection| provider_object(connection) }

    # Dynamic Reconfiguration requires RMC to be active for non-IBMi partitions.
    raise MiqException::MiqVmError, "RMC is not active on target" if rmc_check_required?(lpar)

    # The HMC does not allow changing the VSWITCH or the VLAN of a client network adapter.
    # It could be done by deleting and recreating the adapter with the same MAC and options.
    raise MiqException::MiqVmError, "Cannot edit existing network adapter" if options.key?(:network_adapter_edit)

    spec = {}
    build_memory_config_spec(lpar, spec, options) if options.key?(:vm_memory)
    build_proc_config_spec(lpar, spec, options) if options.key?(:number_of_cpus)
    build_vproc_config_spec(lpar, spec, options) if options.key?(:number_of_vcpus)
    build_netadap_create_config_spec(spec, options) if options.key?(:network_adapter_add)
    build_netadap_delete_config_spec(spec, options) if options.key?(:network_adapter_remove)

    spec
  end

  def rmc_check_required?(lpar)
    lpar.state == "running" && lpar.rmc_state != "active" && !ibmi_partition?(lpar)
  end

  def ibmi_partition?(lpar)
    lpar.try(:type) == "OS400"
  end

  def build_memory_config_spec(lpar, spec, options)
    desired_memory = options[:vm_memory].to_i

    raise MiqException::MiqVmError, "Memory cannot be lower than #{lpar.min_memory} MB"   if desired_memory < lpar.min_memory.to_i
    raise MiqException::MiqVmError, "Memory cannot be greater than #{lpar.max_memory} MB" if desired_memory > lpar.max_memory.to_i

    spec[:desired_memory] = desired_memory
  end

  def build_proc_config_spec(lpar, spec, options)
    if lpar.dedicated == "true"
      min     = lpar.minimum_procs.to_i
      max     = lpar.maximum_procs.to_i
      desired = options[:number_of_cpus].to_i
      raise MiqException::MiqVmError, "Processor count cannot be lower than #{min}"   if desired < min
      raise MiqException::MiqVmError, "Processor count cannot be greater than #{max}" if desired > max

      spec[:desired_procs] = desired
    else
      min     = lpar.minimum_proc_units.to_f
      max     = lpar.maximum_proc_units.to_f
      desired = options[:number_of_cpus].to_f
      raise MiqException::MiqVmError, "Processing units cannot be lower than #{min}"   if desired < min
      raise MiqException::MiqVmError, "Processing units cannot be greater than #{max}" if desired > max

      spec[:desired_proc_units] = desired
    end
  end

  # Builds the virtual processor reconfigure spec for shared partitions.
  # Uses :number_of_vcpus separately from :number_of_cpus, which is handled by
  # build_proc_config_spec for processor count or processing units.
  def build_vproc_config_spec(lpar, spec, options)
    raise MiqException::MiqVmError, "Virtual processors can only be changed on shared processor partitions" if lpar.dedicated == "true"

    desired_vprocs = options[:number_of_vcpus].to_i
    min, max = lpar.minimum_vprocs, lpar.maximum_vprocs

    raise MiqException::MiqVmError, "Virtual processors cannot be lower than #{min}"   if desired_vprocs < min.to_i
    raise MiqException::MiqVmError, "Virtual processors cannot be greater than #{max}" if desired_vprocs > max.to_i

    spec[:desired_vprocs] = desired_vprocs
  end

  def build_netadap_create_config_spec(spec, options)
    spec[:netadap_create] = options[:network_adapter_add].map do |adapt|
      # Retrieve LAN attributes from DB.
      switch_ids = HostSwitch.where(:host_id => host.id).pluck(:switch_id)
      lan = Lan.find_by(:name => adapt[:network], :switch_id => switch_ids)
      raise MiqException::MiqVmError, "Network [#{adapt[:network]}] is not available on target" if lan.nil?

      {
        :sys_uuid     => host.ems_ref,
        :vswitch_uuid => lan.switch.uid_ems,
        :attrs        => {:vlan_id => lan.tag}
      }
    end
  end

  def build_netadap_delete_config_spec(spec, options)
    spec[:netadap_delete] = options[:network_adapter_remove].map do |adapt|
      nic = nics.find_by(:address => adapt[:network][:mac])
      raise MiqException::MiqVmError, "Network adapter [#{adapt[:network][:mac]}] is not available on target" if nic.nil?

      nic.uid_ems
    end
  end

  def raw_reconfigure(spec)
    $ibm_power_hmc_log.debug("reconfiguring with spec=#{spec}")

    ext_management_system.with_provider_connection do |connection|
      attrs = spec.slice(:desired_memory, :desired_procs, :desired_proc_units, :desired_vprocs)
      modify_attrs(connection, attrs) unless attrs.empty?

      spec[:netadap_delete].try(:each) do |uuid|
        connection.network_adapter_lpar_delete(ems_ref, uuid)
      end

      spec[:netadap_create].try(:each) do |netadap|
        connection.network_adapter_lpar_create(ems_ref, netadap[:sys_uuid], netadap[:vswitch_uuid], netadap[:attrs])
      end
    end
  end
end
