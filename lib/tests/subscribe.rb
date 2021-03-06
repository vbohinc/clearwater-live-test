# @file subscribe.rb
#
# Copyright (C) Metaswitch Networks 2017
# If license terms are provided to you in a COPYING file in the root directory
# of the source code repository by which you are accessing this code, then
# the license outlined in that COPYING file applies to your use.
# Otherwise no rights are granted except for those provided to you by
# Metaswitch Networks in a separate written agreement.

def validate_notify xml_s, schema_file="schemas/reginfo.xsd"
  xsd = Nokogiri::XML::Schema(File.read(schema_file))
  reginfo_xml = Nokogiri::XML.parse(xml_s)
  errors = false
  xsd.validate(reginfo_xml).each do |error|
    puts error.message
    errors = true
  end
  if errors
    fail "Could not validate XML against #{schema_file} - see above errors. XML was:\n\n#{xml_s}"
  end
end

TestDefinition.new("SUBSCRIBE - reg-event") do |t|
  ep1 = t.add_endpoint

  t.add_quaff_setup do
    ep1.register
  end

  t.add_quaff_scenario do
    call = ep1.outgoing_call(ep1.uri)

    call.send_request("SUBSCRIBE", "", {"Event" => "reg"})

    # 200 and NOTIFY can come in any order, so expect either of them, twice
    notify1 = call.recv_200_and_notify

    call.send_response("200", "OK")

    # If the registration arrives in the same second as the previous
    # registration, we won't be notified. Sleep for one second to avoid this
    sleep 1

    ep1.register # Re-registration

    notify2 = call.recv_request("NOTIFY")
    call.send_response("200", "OK")

    call.update_branch
    call.send_request("SUBSCRIBE", "", {"Event" => "reg", "From" => notify1.headers['To'], "To" => notify1.headers['From'], "Expires" => 0})

    notify3 = call.recv_200_and_notify

    call.send_response("200", "OK")

    ep1.register # Re-registration

    call.end_call
    fail "NOTIFY responses have invalid CSeq! (same or non-incrementing)" if notify2.header('CSeq').to_i >= notify3.header('CSeq').to_i
    validate_notify notify1.body
    validate_notify notify2.body
    validate_notify notify3.body

    fail "Final Subscription-State header not set to terminated" if notify3.header('Subscription-State') != "terminated;reason=timeout"

  end

  t.add_quaff_cleanup do
    ep1.unregister
  end

end

TestDefinition.new("SUBSCRIBE - reg-event with a GRUU") do |t|
  ep1 = t.add_endpoint

  t.add_quaff_setup do
    ep1.register
  end

  t.add_quaff_scenario do
    call = ep1.outgoing_call(ep1.uri)

    call.send_request("SUBSCRIBE", "", {"Event" => "reg"})

    # 200 and NOTIFY can come in any order, so expect either of them, twice
    notify = call.recv_200_and_notify

    call.send_response("200", "OK")
    validate_notify notify.body

    xmldoc = Nokogiri::XML.parse(notify.body) do |config|
      config.noblanks
    end

    gruu = xmldoc.xpath("//xmlns:registration/xmlns:contact/gr:pub-gruu")

    fail "Binding 1 does not have exactly 1 pub-gruu node in body:\nbody:#{notify.body}" unless (gruu.length == 1)
    fail "Binding 1 has an incorrect pub-gruu node (expected #{ep1.expected_pub_gruu}):\n#{notify.body}" unless (gruu[0]['uri'] == ep1.expected_pub_gruu)
    validate_notify gruu[0].dup.to_s, "schemas/gruuinfo.xsd"
  end

  t.add_quaff_cleanup do
    ep1.unregister
  end


end

# Test that subscriptions are actively timed out on expiry
TestDefinition.new("SUBSCRIBE - Subscription timeout") do |t|
  ep1 = t.add_endpoint

  t.add_quaff_setup do
    ep1.register
  end

  t.add_quaff_scenario do
    call = ep1.outgoing_call(ep1.uri)

    # Set the subscription to expire shortly, sleep until it is nearly expired, then expect a NOTIFY
    call.send_request("SUBSCRIBE", "", {"Event" => "reg", "Expires" => 3})

    # 200 and NOTIFY can come in any order, so expect either of them, twice
    notify1 = call.recv_200_and_notify
    call.send_response("200", "OK")

    sleep 2.5
    notify2 = call.recv_request("NOTIFY")
    call.send_response("200", "OK")

    call.end_call

    # Validate NOTIFYs are correctly formed
    fail "NOTIFY responses have invalid CSeq! (same or non-incrementing)" if notify1.header('CSeq').to_i >= notify2.header('CSeq').to_i

    validate_notify notify1.body
    validate_notify notify2.body

    # Validate that the first NOTIFY was sent as active with the correct expiry.
    # Allow "expires=2" or "expires=1" to cope with timing windows.
    fail "Subscription-State header not indicating active; expiry=x" unless /active;expires=(2|3)/.match(notify1.header('Subscription-State'))

    # Validate that the final NOTIFY was sent due to subscription expiry
    fail "Final Subscription-State header not set to terminated" if notify2.header('Subscription-State') != "terminated;reason=timeout"
  end

  t.add_quaff_cleanup do
    ep1.unregister
  end

end

# Test that registrations are actively timed out on expiry.
TestDefinition.new("SUBSCRIBE - Registration timeout") do |t|
  # This test requires that the minimum expires time on registers is 3s or less,
  # as it will attempt to REGISTER with "Expires: 3"
  t.skip_unless_short_reg_enabled

  ep1 = t.add_endpoint
  ep2 = t.add_public_identity(ep1)

  t.add_quaff_setup do
    ep2.register
  end

  t.add_quaff_scenario do
    call = ep1.outgoing_call(ep1.uri)

    call.send_request("REGISTER", "", { "Expires" => "3", "Authorization" => %Q!Digest username="#{ep1.private_id}"! })
    response_data = call.recv_response("401")
    auth_hdr = Quaff::Auth.gen_auth_header response_data.header("WWW-Authenticate"), ep1.private_id, ep1.password, "REGISTER", ep1.uri
    call.update_branch

    call.send_request("REGISTER", "", {"Authorization" => auth_hdr, "Expires" => "3"})
    response_data = call.recv_response("200")

    sub = ep2.outgoing_call(ep1.uri)
    sub.send_request("SUBSCRIBE", "", {"Event" => "reg"})

    # We expect a 200 OK to the SUBSCRIBE and an immediate NOTIFY giving us the
    # current state. These can come in any order, so expect either of them in
    # response to our SUBSCRIBE
    notify1 = sub.recv_200_and_notify
    sub.send_response("200", "OK")

    # Expect a NOTIFY to be generated for ep1's registration expiring after a
    # few seconds
    notify2 = sub.recv_request("NOTIFY")
    sub.send_response("200", "OK")

    sub.end_call
    call.end_call

    # Validate NOTIFYs are correctly formed
    if notify1.header('CSeq').to_i >= notify2.header('CSeq').to_i
      fail "NOTIFY responses have same or non-incrementing CSeq - \
first one had '#{notify1.header('CSeq')}', second one had '#{notify2.header('CSeq')}'"
    end

    validate_notify notify1.body
    validate_notify notify2.body

    # Validate that the NOTIFY body indicates is was triggered by the registration expiring
    xmldoc = Nokogiri::XML.parse(notify2.body) do |config|
      config.noblanks
    end

    fail "NOTIFY does not indicate register has expired" unless (xmldoc.child.child.children[0]['event'] == "expired")
  end

  t.add_quaff_cleanup do
    ep2.unregister

    # Speculatively try to unregister ep1 in case the test failed and the
    # registration didn't time out correctly, but don't fail the test if this
    # fails.
    begin
      ep1.unregister
    rescue
      # Ignore the error
    end
  end

end

TestDefinition.new("Multiple SUBSCRIBErs to one UE's reg-event") do |t|
  ep1 = t.add_endpoint
  ep2 = t.add_public_identity(ep1)

  t.add_quaff_setup do
    ep1.register
    ep2.register
  end

  t.add_quaff_scenario do
    call = ep1.outgoing_call(ep1.uri)

    call.send_request("SUBSCRIBE", "", {"Event" => "reg"})

    # 200 and NOTIFY can come in any order, so expect either of them, twice
    notify1 = call.recv_200_and_notify

    call.send_response("200", "OK")

    # Second endpoint subscribes to first endpoint's registration state
    call2 = ep2.outgoing_call(ep1.uri)
    call2.send_request("SUBSCRIBE", "", {"Event" => "reg"})

    notify2 = call2.recv_200_and_notify
    call2.send_response("200", "OK")

    # If the registration arrives in the same second as the previous
    # registration, we won't be notified. Sleep for one second to avoid this
    sleep 1

    ep1.register # Re-registration
    notify3 = call.recv_request("NOTIFY")
    call.send_response("200", "OK")
    notify4 = call2.recv_request("NOTIFY")
    call2.send_response("200", "OK")

    call2.update_branch

    # Second endpoint resubscribes
    call2.send_request("SUBSCRIBE", "", {"Event" => "reg",
                                         "From" => notify2.headers['To'],
                                         "To" => notify2.headers['From'],
                                         "Expires" => "0"})

    notify5 = call2.recv_200_and_notify
    call2.send_response("200", "OK")
    fail "Final Subscription-State header (from ep2) not set to terminated" if notify5.header('Subscription-State') != "terminated;reason=timeout"

    # Terminate first endpoint subscription
    call.update_branch
    call.send_request("SUBSCRIBE", "", {"Event" => "reg",
                                        "From" => notify1.headers['To'],
                                        "To" => notify1.headers['From'],
                                        "Expires" => "0"})

    notify6 = call.recv_200_and_notify
    call.send_response("200", "OK")
    fail "Final Subscription-State header (from ep1) not set to terminated" if notify6.header('Subscription-State') != "terminated;reason=timeout"

    call.end_call
    call2.end_call

    validate_notify notify1.body
    validate_notify notify2.body
    validate_notify notify3.body
    validate_notify notify4.body
    validate_notify notify5.body
    validate_notify notify6.body
  end

  t.add_quaff_cleanup do
    ep1.unregister
    ep2.unregister
  end

end
