require "http/client"
require "json"

module Cloudflare
  API_BASE = "https://api.cloudflare.com/client/v4"
  ZONE_ID = ENV["CF_ZONE_ID"]? || raise "CF_ZONE_ID environment variable not set"
  API_TOKEN = ENV["CF_API_TOKEN"]? || raise "CF_API_TOKEN environment variable not set"

  struct EmailRule
    property id : String
    property enabled : Bool
    property matchers : Array(Matcher)
    property actions : Array(Action)
    
    def initialize(@id = "", @enabled = true, @matchers = [] of Matcher, @actions = [] of Action)
    end
  end

  struct Matcher
    property field : String
    property value : String
    property type : String
    
    def initialize(@field : String, @value : String, @type : String = "literal")
    end
  end

  struct Action
    property type : String
    property value : Array(String)
    
    def initialize(@type : String, @value : Array(String))
    end
  end

  def self.create_forward(email_address : String, forward_to : String) : Tuple(Bool, String)
    rule = EmailRule.new(
      matchers: [Matcher.new("to", email_address)],
      actions: [Action.new("forward", [forward_to])]
    )

    response = HTTP::Client.post(
      "#{API_BASE}/zones/#{ZONE_ID}/email/routing/rules",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{API_TOKEN}"],
        "Content-Type" => ["application/json"]
      },
      body: rule.to_json
    )

    if response.status_code == 200
      data = JSON.parse(response.body)
      if data["success"] == true
        rule_id = data["result"]["id"]?.try(&.as_s) || ""
        return {true, rule_id}
      end
    end
    
    {false, response.body}
  rescue ex
    {false, ex.message.to_s}
  end

  def self.delete_forward(rule_id : String) : Bool
    response = HTTP::Client.delete(
      "#{API_BASE}/zones/#{ZONE_ID}/email/routing/rules/#{rule_id}",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{API_TOKEN}"],
        "Content-Type" => ["application/json"]
      }
    )

    if response.status_code == 200
      data = JSON.parse(response.body)
      return data["success"] == true
    end
    
    false
  rescue
    false
  end

  def self.get_rules : Array(EmailRule)
    response = HTTP::Client.get(
      "#{API_BASE}/zones/#{ZONE_ID}/email/routing/rules",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{API_TOKEN}"],
        "Content-Type" => ["application/json"]
      }
    )

    rules = [] of EmailRule
    
    if response.status_code == 200
      data = JSON.parse(response.body)
      if data["success"] == true
        data["result"].as_a.each do |rule_data|
          rule = EmailRule.new(
            id: rule_data["id"]?.try(&.as_s) || "",
            enabled: rule_data["enabled"]?.try(&.as_bool) || false
          )
          rules << rule
        end
      end
    end
    
    rules
  rescue
    rules
  end

  def self.rule_exists_for_email(email_address : String) : Bool
    response = HTTP::Client.get(
      "#{API_BASE}/zones/#{ZONE_ID}/email/routing/rules",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{API_TOKEN}"],
        "Content-Type" => ["application/json"]
      }
    )

    if response.status_code == 200
      data = JSON.parse(response.body)
      if data["success"] == true
        data["result"].as_a.each do |rule|
          matchers = rule["matchers"]?.try(&.as_a) || [] of JSON::Any
          matchers.each do |matcher|
            if matcher["field"]?.try(&.as_s) == "to" && matcher["value"]?.try(&.as_s) == email_address
              return true
            end
          end
        end
      end
    end
    
    false
  rescue
    false
  end

  def self.sync_alias(alias_obj : Alias, action : String) : Tuple(Bool, String)
    email = alias_obj.full_email
    forward_to = alias_obj.forward_to
    
    case action
    when "create"
      # Check if rule already exists
      if rule_exists_for_email(email)
        return {false, "Rule already exists for #{email}"}
      end
      create_forward(email, forward_to)
      
    when "delete"
      # Need to find rule ID for this email first
      rules = get_rules
      rules.each do |rule|
        # Check if this rule matches our email
        response = HTTP::Client.get(
          "#{API_BASE}/zones/#{ZONE_ID}/email/routing/rules/#{rule.id}",
          headers: HTTP::Headers{"Authorization" => ["Bearer #{API_TOKEN}"]}
        )
        
        if response.status_code == 200
          data = JSON.parse(response.body)
          if data["success"] == true
            matchers = data["result"]["matchers"]?.try(&.as_a) || [] of JSON::Any
            matchers.each do |matcher|
              if matcher["field"]?.try(&.as_s) == "to" && matcher["value"]?.try(&.as_s) == email
                return delete_forward(rule.id) ? {true, "Deleted"} : {false, "Failed to delete"}
              end
            end
          end
        end
      end
      {false, "Rule not found for #{email}"}
      
    else
      {false, "Unknown action"}
    end
  end
end
