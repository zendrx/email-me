require "http/client"
require "json"
require "openssl"

module Paystack
  SECRET_KEY = ENV["PAYSTACK_SECRET_KEY"]? || raise "PAYSTACK_SECRET_KEY not set"
  PUBLIC_KEY = ENV["PAYSTACK_PUBLIC_KEY"]? || raise "PAYSTACK_PUBLIC_KEY not set"
  API_BASE = "https://api.paystack.co"
  
  # Amounts in kobo (400000 kobo = ₦4000, 750000 kobo = ₦7500)
  PRO_AMOUNT = 400_000
  UNLIMITED_AMOUNT = 750_000
  
  struct InitializeResponse
    include JSON::Serializable

    property status : Bool
    property message : String
    property data : InitializeData?

    def initialize(@status : Bool, @message : String, @data : InitializeData?)
    end
  end
  
  struct InitializeData
    include JSON::Serializable

    property authorization_url : String
    property access_code : String
    property reference : String

    def initialize(@authorization_url : String, @access_code : String, @reference : String)
    end
  end
  
  struct VerifyResponse
    include JSON::Serializable

    property status : Bool
    property message : String
    property data : VerifyData?

    def initialize(@status : Bool, @message : String, @data : VerifyData?)
    end
  end
  
  struct VerifyData
    include JSON::Serializable

    property amount : Int32
    property currency : String
    property status : String
    property reference : String
    property metadata : Metadata?

    def initialize(@amount : Int32, @currency : String, @status : String, @reference : String, @metadata : Metadata?)
    end
  end
  
  struct Metadata
    include JSON::Serializable

    property user_id : Int32
    property plan : String

    def initialize(@user_id : Int32, @plan : String)
    end
  end
  
  struct WebhookEvent
    include JSON::Serializable

    property event : String
    property data : WebhookData

    def initialize(@event : String, @data : WebhookData)
    end
  end
  
  struct WebhookData
    include JSON::Serializable

    property reference : String
    property amount : Int32
    property status : String
    property customer : WebhookCustomer
    property metadata : Metadata?

    def initialize(@reference : String, @amount : Int32, @status : String, @customer : WebhookCustomer, @metadata : Metadata?)
    end
  end
  
  struct WebhookCustomer
    include JSON::Serializable

    property email : String
    property first_name : String?
    property last_name : String?

    def initialize(@email : String, @first_name : String?, @last_name : String?)
    end
  end
  
  # Initialize a transaction
  def self.initialize_transaction(email : String, amount : Int32, plan : String, user_id : Int32, callback_url : String) : InitializeResponse
    reference = generate_reference
    
    body = {
      email: email,
      amount: amount,
      currency: "NGN",
      reference: reference,
      callback_url: callback_url,
      metadata: {
        user_id: user_id,
        plan: plan
      }
    }.to_json
    
    response = HTTP::Client.post(
      "#{API_BASE}/transaction/initialize",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{SECRET_KEY}"],
        "Content-Type" => ["application/json"]
      },
      body: body
    )
    
    if response.status_code == 200
      InitializeResponse.from_json(response.body)
    else
      InitializeResponse.new(status: false, message: "Failed to initialize payment", data: nil)
    end
  rescue ex
    InitializeResponse.new(status: false, message: ex.message.to_s, data: nil)
  end
  
  # Verify a transaction
  def self.verify_transaction(reference : String) : VerifyResponse
    response = HTTP::Client.get(
      "#{API_BASE}/transaction/verify/#{reference}",
      headers: HTTP::Headers{
        "Authorization" => ["Bearer #{SECRET_KEY}"]
      }
    )
    
    if response.status_code == 200
      VerifyResponse.from_json(response.body)
    else
      VerifyResponse.new(status: false, message: "Verification failed", data: nil)
    end
  rescue ex
    VerifyResponse.new(status: false, message: ex.message.to_s, data: nil)
  end
  
  # Verify webhook signature
  def self.verify_signature(payload : String, signature : String) : Bool
    computed = OpenSSL::HMAC.hexdigest(:sha512, SECRET_KEY, payload)
    computed == signature
  rescue
    false
  end
  
  # Parse webhook event
  def self.parse_webhook(payload : String, signature : String) : WebhookEvent?
    return nil unless verify_signature(payload, signature)
    
    begin
      WebhookEvent.from_json(payload)
    rescue
      nil
    end
  end
  
  private def self.generate_reference : String
    "EM-#{Time.utc.to_unix}-#{Random::Secure.hex(6)}"
  end
end
