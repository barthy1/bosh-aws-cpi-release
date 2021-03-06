require 'json'

module Bosh::AwsCloud
  class InstanceParamMapper
    attr_accessor :manifest_params

    def initialize(security_group_mapper)
      @manifest_params = {}
      @security_group_mapper = security_group_mapper
    end

    def validate
      validate_required_inputs
      validate_availability_zone
    end

    def validate_required_inputs
      required_top_level = [
        'stemcell_id',
        'registry_endpoint'
      ]
      required_vm_type = [
        'instance_type',
        'availability_zone'
      ]
      missing_inputs = []

      required_top_level.each do |input_name|
        missing_inputs << input_name unless @manifest_params[input_name.to_sym]
      end
      required_vm_type.each do |input_name|
        missing_inputs << "cloud_properties.#{input_name}" unless vm_type[input_name]
      end

      unless key_name
        missing_inputs << "(cloud_properties.key_name or defaults.default_key_name)"
      end

      sg = security_groups
      if ( sg.nil? || sg.empty? )
        missing_inputs << "(cloud_properties.security_groups or defaults.default_security_groups)"
      end

      if subnet_id.nil?
        missing_inputs << "cloud_properties.subnet_id"
      end

      unless missing_inputs.empty?
        raise Bosh::Clouds::CloudError, "Missing properties: #{missing_inputs.join(', ')}. See http://bosh.io/docs/aws-cpi.html for the list of supported properties."
      end
    end

    def validate_availability_zone
      # Check to see if provided availability zones match
      availability_zone
    end

    def instance_params
      params = {
        image_id: @manifest_params[:stemcell_id],
        instance_type: vm_type['instance_type'],
        key_name: key_name,
        iam_instance_profile: iam_instance_profile,
        user_data: user_data,
        block_device_mappings: @manifest_params[:block_device_mappings]
      }

      az = availability_zone
      placement = {}
      placement[:group_name] = vm_type['placement_group'] if vm_type['placement_group']
      placement[:availability_zone] = az if az
      placement[:tenancy] = 'dedicated' if vm_type['tenancy'] == 'dedicated'
      params[:placement] = placement unless placement.empty?

      sg = @security_group_mapper.map_to_ids(security_groups, subnet_id)

      nic = {}
      nic[:groups] = sg unless sg.nil? || sg.empty?
      nic[:subnet_id] = subnet_id if subnet_id
      nic[:private_ip_address] = private_ip_address if private_ip_address
      nic[:associate_public_ip_address] = vm_type['auto_assign_public_ip'] if vm_type['auto_assign_public_ip']

      nic[:device_index] = 0 unless nic.empty?
      params[:network_interfaces] = [nic] unless nic.empty?

      params.delete_if { |k, v| v.nil? }
    end

    private

    def vm_type
      @manifest_params[:vm_type] || {}
    end

    def networks_spec
      @manifest_params[:networks_spec] || {}
    end

    def defaults
      @manifest_params[:defaults] || {}
    end

    def volume_zones
      @manifest_params[:volume_zones] || []
    end

    def subnet_az_mapping
      @manifest_params[:subnet_az_mapping] || {}
    end

    def key_name
      vm_type["key_name"] || defaults["default_key_name"]
    end

    def iam_instance_profile
      profile_name = vm_type["iam_instance_profile"] || defaults["default_iam_instance_profile"]
      { name: profile_name } if profile_name
    end

    def security_groups
      groups = vm_type["security_groups"] || extract_security_groups(networks_spec)
      groups.empty? ? defaults["default_security_groups"] : groups
    end

    def user_data
      user_data = {}
      user_data[:registry] = { endpoint: @manifest_params[:registry_endpoint] } if @manifest_params[:registry_endpoint]

      spec_with_dns = networks_spec.values.select { |spec| spec.has_key? "dns" }.first
      user_data[:dns] = {nameserver: spec_with_dns["dns"]} if spec_with_dns

      Base64.encode64(user_data.to_json).strip unless user_data.empty?
    end

    def private_ip_address
      manual_network_spec = networks_spec.values.select do |spec|
        ["manual", nil].include?(spec["type"])
      end.first || {}
      manual_network_spec["ip"]
    end

    # NOTE: do NOT lookup the subnet (from EC2 client) anymore. We just need to
    # pass along the subnet_id anyway, and we have that.
    def subnet_id
      subnet_network_spec = networks_spec.values.select do |spec|
        ["manual", nil, "dynamic"].include?(spec["type"]) &&
          spec.fetch("cloud_properties", {}).has_key?("subnet")
      end.first

      subnet_network_spec["cloud_properties"]["subnet"] if subnet_network_spec
    end

    def availability_zone
      az_selector = AvailabilityZoneSelector.new(nil)
      az_selector.common_availability_zone(
        volume_zones,
        vm_type["availability_zone"],
        subnet_az_mapping[subnet_id]
      )
    end

    def extract_security_groups(networks_spec)
      networks_spec.
          values.
          select { |network_spec| network_spec.has_key? "cloud_properties" }.
          map { |network_spec| network_spec["cloud_properties"] }.
          select { |cloud_properties| cloud_properties.has_key? "security_groups" }.
          map { |cloud_properties| Array(cloud_properties["security_groups"]) }.
          flatten.
          sort.
          uniq
    end

  end
end
