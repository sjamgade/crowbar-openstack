# Copyright 2016 SUSE Linux GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "yaml"

package "openstack-designate"

network_settings = DesignateHelper.network_settings(node)
db_settings = fetch_database_settings

include_recipe "database::client"
include_recipe "#{db_settings[:backend_name]}::client"
include_recipe "#{db_settings[:backend_name]}::python-client"

public_host = CrowbarHelper.get_host_for_public_url(node,
                                                    node[:designate][:api][:protocol] == "https",
                                                    node[:designate][:ha][:enabled])

# get Database data
sql_connection = fetch_database_connection_string(node[:designate][:db])

memcached_servers = MemcachedHelper.get_memcached_servers(
  if node[:designate][:ha][:enabled]
    CrowbarPacemakerHelper.cluster_nodes(node, "designate-server")
  else
    [node]
  end
)

memcached_instance("designate") if node["roles"].include?("designate-server")

api_protocol = node[:designate][:api][:protocol]

template node[:designate][:config_file] do
  source "designate.conf.erb"
  owner "root"
  group node[:designate][:group]
  mode "0640"
  variables(
    bind_host: network_settings[:api][:bind_host],
    bind_port: network_settings[:api][:bind_port],
    api_base_uri: "#{api_protocol}://#{public_host}:#{node[:designate][:api][:bind_port]}",
    sql_connection: sql_connection,
    rabbit_settings: fetch_rabbitmq_settings,
    keystone_settings: KeystoneHelper.keystone_settings(node, :designate),
    memcached_servers: memcached_servers
  )
end

dnsserv = node_search_with_cache("roles:dns-server").first
dnsmaster = dnsserv[:dns][:master_ip]
dnsslaves = dnsserv[:dns][:slave_ips]
mdnsaddr = Barclamp::Inventory.get_network_by_type(node, "admin").address

pools = [{
      "name"=>"default-bind",
      "description"=>"Default BIND9 Pool",
      "id" => "794ccc2c-d751-44fe-b57f-8894c9f5c842",
      "attributes"=>{},
      "ns_records"=> [{"hostname" => "#{dnsserv[:fqdn]}.", "priority" => 1}],
      "nameservers"=> [{"host"=>"127.0.0.1", "port"=>53}],
      "also_notifies"=> dnsslaves.map do |ip| {"host" => ip , "port" => 53 } end,
      "targets"=> [{
        "type"=>"bind9",
        "description"=>"BIND9 Server 1",
        "masters"=>[{ "host" => mdnsaddr, "port" => 5354 }],
        "options"=> {
          "host"=>"127.0.0.1",
          "port"=>53,
          "rndc_host"=>dnsmaster,
          "rndc_port"=>953,
          "rndc_key_file"=>"/etc/designate/rndc.key"}},
]}]

file "/etc/designate/pools.crowbar.yaml" do
  owner "root"
  group node[:designate][:group]
  mode "0640"
  content pools.to_yaml
end

template "/etc/designate/rndc.key" do
  source "rndc.key.erb"
  owner "root"
  group node[:designate][:group]
  mode "0640"
  variables(rndc_key: dnsserv[:dns][:designate_rndc_key])
end
