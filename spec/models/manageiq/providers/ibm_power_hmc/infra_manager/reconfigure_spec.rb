describe ManageIQ::Providers::IbmPowerHmc::InfraManager::Lpar do
  let(:ems) { FactoryBot.create(:ems_ibm_power_hmc_infra_with_authentication) }

  let(:host) do
    host = FactoryBot.create(:ibm_power_hmc_host, :ext_management_system => ems, :ems_ref => "host-uuid-1")
    host.create_hardware(:memory_mb => 65_536, :cpu_total_cores => 16)
    host
  end

  let(:vm) do
    vm = FactoryBot.create(
      :ibm_power_hmc_lpar,
      :ext_management_system => ems,
      :ems_ref               => "lpar-uuid-1",
      :host                  => host
    )
    vm.create_hardware(:cpu_total_cores => 4)
    vm
  end

  let(:conn)  { double("IbmPowerHmc::Connection") }
  let(:lpar)  { double("IbmPowerHmc::LogicalPartition") }

  before do
    allow(ems).to receive(:with_provider_connection).and_yield(conn)
    allow(conn).to receive(:lpar).with(vm.ems_ref).and_return(lpar)
    allow(vm).to receive(:provider_object).with(conn).and_return(lpar)
    allow(lpar).to receive(:state).and_return("not activated")
    allow(lpar).to receive(:rmc_state).and_return("inactive")
  end

  describe "#reconfigurable?" do
    it "returns true when host is HMC-managed" do
      host.advanced_settings.create!(:name => "hmc_managed", :value => "true")
      expect(vm.reconfigurable?).to be true
    end

    it "returns false when host is not HMC-managed" do
      host.advanced_settings.create!(:name => "hmc_managed", :value => "false")
      expect(vm.reconfigurable?).to be false
    end

    it "returns false when there is no hmc_managed setting" do
      expect(vm.reconfigurable?).to be_falsey
    end
  end

  describe "#max_total_vcpus" do
    it "returns 64 for a shared processor partition" do
      vm.advanced_settings.create!(:name => "processor_type", :value => "shared")
      expect(vm.max_total_vcpus).to eq(64)
    end

    it "returns host cpu_total_cores for a dedicated processor partition" do
      vm.advanced_settings.create!(:name => "processor_type", :value => "dedicated")
      expect(vm.max_total_vcpus).to eq(host.cpu_total_cores)
    end

    it "returns 64 when the VM has no host" do
      vm.host = nil
      expect(vm.max_total_vcpus).to eq(64)
    end
  end

  describe "#max_vcpus" do
    it "delegates to max_total_vcpus" do
      expect(vm.max_vcpus).to eq(vm.max_total_vcpus)
    end
  end

  describe "#reconfigure_vcpu_limits" do
    it "returns a hash with min 1 and max equal to max_total_vcpus" do
      vm.advanced_settings.create!(:name => "processor_type", :value => "shared")
      expect(vm.reconfigure_vcpu_limits).to eq(:min => 1, :max => 64)
    end
  end

  describe "#current_vcpu_count" do
    it "returns cpu_total_cores as an integer" do
      expect(vm.current_vcpu_count).to eq(4)
    end
  end

  describe "#max_cpu_cores_per_socket" do
    it "always returns 1" do
      expect(vm.max_cpu_cores_per_socket).to eq(1)
      expect(vm.max_cpu_cores_per_socket(8)).to eq(1)
    end
  end

  describe "#max_memory_mb" do
    it "returns host hardware memory when host is present" do
      expect(vm.max_memory_mb).to eq(65_536)
    end

    it "returns 1_024 when the VM has no host" do
      vm.host = nil
      expect(vm.max_memory_mb).to eq(1_024)
    end
  end

  describe "supports? :reconfigure_proc_units" do
    it "is always supported" do
      expect(vm.supports?(:reconfigure_proc_units)).to be true
    end
  end

  describe "supports? :reconfigure_vcpus" do
    it "is supported for shared processor partitions" do
      vm.advanced_settings.create!(:name => "processor_type", :value => "shared")
      expect(vm.supports?(:reconfigure_vcpus)).to be true
    end

    it "is not supported for dedicated processor partitions" do
      vm.advanced_settings.create!(:name => "processor_type", :value => "dedicated")
      expect(vm.supports?(:reconfigure_vcpus)).to be false
    end
  end

  describe "#build_config_spec" do
    before do
      allow(ems).to receive(:with_provider_connection) { |&block| block.call(conn) }
    end

    it "raises MiqVmError when RMC is inactive on a running partition" do
      allow(lpar).to receive(:state).and_return("running")
      allow(lpar).to receive(:rmc_state).and_return("inactive")
      expect { vm.build_config_spec(:vm_memory => 2048) }
        .to raise_error(MiqException::MiqVmError, /RMC is not active/)
    end

    it "raises MiqVmError when attempting to edit an existing network adapter" do
      expect { vm.build_config_spec(:network_adapter_edit => {}) }
        .to raise_error(MiqException::MiqVmError, /Cannot edit existing network adapter/)
    end

    context "memory" do
      before do
        allow(lpar).to receive(:min_memory).and_return(512)
        allow(lpar).to receive(:max_memory).and_return(8192)
      end

      it "sets desired_memory in the spec" do
        spec = vm.build_config_spec(:vm_memory => 2048)
        expect(spec[:desired_memory]).to eq(2048)
      end

      it "raises MiqVmError when memory is below the minimum" do
        expect { vm.build_config_spec(:vm_memory => 256) }
          .to raise_error(MiqException::MiqVmError, /Memory cannot be lower than/)
      end

      it "raises MiqVmError when memory exceeds the maximum" do
        expect { vm.build_config_spec(:vm_memory => 16_384) }
          .to raise_error(MiqException::MiqVmError, /Memory cannot be greater than/)
      end
    end

    context "dedicated processors" do
      before do
        allow(lpar).to receive(:dedicated).and_return("true")
        allow(lpar).to receive(:minimum_procs).and_return(1)
        allow(lpar).to receive(:maximum_procs).and_return(8)
      end

      it "sets desired_procs in the spec" do
        spec = vm.build_config_spec(:number_of_cpus => 4)
        expect(spec[:desired_procs]).to eq(4)
      end

      it "raises MiqVmError when proc count is below minimum" do
        expect { vm.build_config_spec(:number_of_cpus => 0) }
          .to raise_error(MiqException::MiqVmError, /Processor count cannot be lower than/)
      end

      it "raises MiqVmError when proc count exceeds maximum" do
        expect { vm.build_config_spec(:number_of_cpus => 16) }
          .to raise_error(MiqException::MiqVmError, /Processor count cannot be greater than/)
      end
    end

    context "shared processors (processing units)" do
      before do
        allow(lpar).to receive(:dedicated).and_return("false")
        allow(lpar).to receive(:minimum_proc_units).and_return(0.1)
        allow(lpar).to receive(:maximum_proc_units).and_return(4.0)
      end

      it "sets desired_proc_units in the spec" do
        spec = vm.build_config_spec(:number_of_cpus => 2.0)
        expect(spec[:desired_proc_units]).to eq(2.0)
      end

      it "raises MiqVmError when processing units are below minimum" do
        expect { vm.build_config_spec(:number_of_cpus => 0.0) }
          .to raise_error(MiqException::MiqVmError, /Processing units cannot be lower than/)
      end

      it "raises MiqVmError when processing units exceed maximum" do
        expect { vm.build_config_spec(:number_of_cpus => 8.0) }
          .to raise_error(MiqException::MiqVmError, /Processing units cannot be greater than/)
      end
    end

    context "virtual processors (shared partition)" do
      before do
        allow(lpar).to receive(:dedicated).and_return("false")
        allow(lpar).to receive(:minimum_vprocs).and_return(1)
        allow(lpar).to receive(:maximum_vprocs).and_return(8)
      end

      it "sets desired_vprocs in the spec" do
        spec = vm.build_config_spec(:number_of_vcpus => 4)
        expect(spec[:desired_vprocs]).to eq(4)
      end

      it "raises MiqVmError when vproc count is below minimum" do
        expect { vm.build_config_spec(:number_of_vcpus => 0) }
          .to raise_error(MiqException::MiqVmError, /Virtual processors cannot be lower than/)
      end

      it "raises MiqVmError when vproc count exceeds maximum" do
        expect { vm.build_config_spec(:number_of_vcpus => 16) }
          .to raise_error(MiqException::MiqVmError, /Virtual processors cannot be greater than/)
      end

      it "raises MiqVmError when attempting to set vprocs on a dedicated partition" do
        allow(lpar).to receive(:dedicated).and_return("true")
        expect { vm.build_config_spec(:number_of_vcpus => 4) }
          .to raise_error(MiqException::MiqVmError, /Virtual processors can only be changed on shared/)
      end
    end

    context "network adapter add" do
      let(:switch) { FactoryBot.create(:switch, :uid_ems => "vswitch-uuid-1") }
      let(:lan)    { FactoryBot.create(:lan, :name => "net-1", :switch => switch, :tag => "100") }

      before { HostSwitch.create!(:host => host, :switch => switch) }

      it "sets netadap_create in the spec" do
        spec = vm.build_config_spec(:network_adapter_add => [{:network => lan.name}])
        expect(spec[:netadap_create]).to contain_exactly(
          :sys_uuid     => host.ems_ref,
          :vswitch_uuid => "vswitch-uuid-1",
          :attrs        => {:vlan_id => "100"}
        )
      end

      it "raises MiqVmError when the network is not available on the host" do
        expect { vm.build_config_spec(:network_adapter_add => [{:network => "unknown-net"}]) }
          .to raise_error(MiqException::MiqVmError, /Network \[unknown-net\] is not available on target/)
      end
    end

    context "network adapter remove" do
      let!(:nic) { FactoryBot.create(:guest_device_nic, :hardware => vm.hardware || FactoryBot.create(:hardware, :vm_or_template => vm), :address => "aa:bb:cc:dd:ee:ff", :uid_ems => "cna-uuid-1") }

      it "sets netadap_delete in the spec" do
        spec = vm.build_config_spec(:network_adapter_remove => [{:network => {:mac => "aa:bb:cc:dd:ee:ff"}}])
        expect(spec[:netadap_delete]).to eq(["cna-uuid-1"])
      end

      it "raises MiqVmError when the adapter MAC is not found" do
        expect { vm.build_config_spec(:network_adapter_remove => [{:network => {:mac => "00:11:22:33:44:55"}}]) }
          .to raise_error(MiqException::MiqVmError, /Network adapter \[00:11:22:33:44:55\] is not available on target/)
      end
    end
  end

  describe "#raw_reconfigure" do
    before do
      allow(vm).to receive(:modify_attrs)
    end

    it "calls modify_attrs with memory and processor slices from the spec" do
      spec = {:desired_memory => 4096, :desired_procs => 2}
      expect(vm).to receive(:modify_attrs).with(conn, spec)
      vm.raw_reconfigure(spec)
    end

    it "omits keys unrelated to attributes from modify_attrs" do
      spec = {:desired_memory => 2048, :netadap_delete => ["uuid-1"]}
      expect(vm).to receive(:modify_attrs).with(conn, hash_including(:desired_memory => 2048))
      allow(conn).to receive(:network_adapter_lpar_delete)
      vm.raw_reconfigure(spec)
    end

    it "calls network_adapter_lpar_delete for each uuid in netadap_delete" do
      spec = {:netadap_delete => ["cna-uuid-1", "cna-uuid-2"]}
      allow(vm).to receive(:modify_attrs)
      expect(conn).to receive(:network_adapter_lpar_delete).with(vm.ems_ref, "cna-uuid-1")
      expect(conn).to receive(:network_adapter_lpar_delete).with(vm.ems_ref, "cna-uuid-2")
      vm.raw_reconfigure(spec)
    end

    it "calls network_adapter_lpar_create for each entry in netadap_create" do
      netadap = {:sys_uuid => "sys-1", :vswitch_uuid => "vsw-1", :attrs => {:vlan_id => "10"}}
      spec    = {:netadap_create => [netadap]}
      allow(vm).to receive(:modify_attrs)
      expect(conn).to receive(:network_adapter_lpar_create).with(vm.ems_ref, "sys-1", "vsw-1", hash_including(:vlan_id => "10"))
      vm.raw_reconfigure(spec)
    end

    it "skips modify_attrs when spec contains no attribute keys" do
      spec = {:netadap_delete => ["uuid-1"]}
      expect(vm).not_to receive(:modify_attrs)
      allow(conn).to receive(:network_adapter_lpar_delete)
      vm.raw_reconfigure(spec)
    end
  end
end
