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
    JSON.mapping(
      status: Bool,
      message: String,
      data: InitializeData?
    )
  end
  
  struct InitializeData
    JSON.mapping(
      authorization_url: String,
      access_code: String,
      reference: String
    )
  end
  
  struct VerifyResponse
    JSON.mapping(
      status: Bool,
      message: String,
      data: VerifyData?
    )
  end
  
  struct VerifyData
    JSON.mapping(
      amount: Int32,
      currency: String,
      status: String,
      reference: String,
      metadata: Metadata?
    )
  end
  
  struct Metadata
    JSON.mapping(
      user_id: Int32,
      plan: String
    )
  end
  
  struct WebhookEvent
    JSON.mapping(
      event: String,
      data: WebhookData
    )
  end
  
  struct WebhookData
    JSON.mapping(
      reference: String,
      amount: Int32,
      status: String,
      customer: WebhookCustomer,
      metadata: Metadata?
    )
  end
  
  struct WebhookCustomer
    JSON.mapping(
      email: String,
      first_name: String?,
      last_name: String?
    )
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
