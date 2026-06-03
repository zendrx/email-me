require "sqlite3"

module DAB
  DB_PATH = "sqlite3://./email_me.db"
  
  # Returns a new connection each time
  private def self.db
    DB.open(DB_PATH)
  end
  
  def self.setup
    DB.open(DB_PATH) do |db|
      # Users table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT UNIQUE NOT NULL,
          username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          plan TEXT DEFAULT 'Free',
          forward_email TEXT,
          stripe_customer_id TEXT,
          created_at TIMESTAMP NOT NULL
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
      SQL

      # Aliases table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS aliases (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          local_part TEXT NOT NULL,
          domain TEXT NOT NULL,
          forward_to TEXT NOT NULL,
          active BOOLEAN DEFAULT TRUE,
          created_at TIMESTAMP NOT NULL,
          FOREIGN KEY (user_id) REFERENCES users(id),
          UNIQUE(local_part, domain)
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_aliases_user_id ON aliases(user_id);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_aliases_email ON aliases(local_part, domain);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_aliases_active ON aliases(active);
      SQL

      # Domains table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS domains (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          domain TEXT UNIQUE NOT NULL,
          owner_id INTEGER NOT NULL,
          verified BOOLEAN DEFAULT FALSE,
          dns_verified_at TIMESTAMP,
          created_at TIMESTAMP NOT NULL,
          FOREIGN KEY (owner_id) REFERENCES users(id)
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_domains_owner_id ON domains(owner_id);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_domains_domain ON domains(domain);
      SQL

      # Team members table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS team_members (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          domain_id INTEGER NOT NULL,
          user_id INTEGER NOT NULL,
          role TEXT NOT NULL DEFAULT 'member',
          invited_by INTEGER NOT NULL,
          created_at TIMESTAMP NOT NULL,
          FOREIGN KEY (domain_id) REFERENCES domains(id),
          FOREIGN KEY (user_id) REFERENCES users(id),
          FOREIGN KEY (invited_by) REFERENCES users(id),
          UNIQUE(domain_id, user_id)
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_team_members_domain_id ON team_members(domain_id);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_team_members_user_id ON team_members(user_id);
      SQL

      # Cloudflare rules mapping table (store rule IDs for sync)
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS cloudflare_rules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          alias_id INTEGER NOT NULL,
          rule_id TEXT NOT NULL,
          created_at TIMESTAMP NOT NULL,
          FOREIGN KEY (alias_id) REFERENCES aliases(id),
          UNIQUE(alias_id)
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_cf_rules_alias_id ON cloudflare_rules(alias_id);
      SQL

      # Payment transactions table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          reference TEXT UNIQUE NOT NULL,
          amount INTEGER NOT NULL,
          plan TEXT NOT NULL,
          status TEXT NOT NULL,
          paid_at TIMESTAMP,
          created_at TIMESTAMP NOT NULL,
          FOREIGN KEY (user_id) REFERENCES users(id)
        );
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id);
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_transactions_reference ON transactions(reference);
      SQL

      puts "Database setup complete"
    end
  end

  # User methods
  def self.email_exists?(email : String) : Bool
    DB.open(DB_PATH) do |db|
      result = db.query_one?("SELECT 1 FROM users WHERE email = ? LIMIT 1", email, as: Int32)
      !result.nil?
    end
  end

  def self.username_exists?(username : String) : Bool
    DB.open(DB_PATH) do |db|
      result = db.query_one?("SELECT 1 FROM users WHERE username = ? LIMIT 1", username, as: Int32)
      !result.nil?
    end
  end

  def self.create_user(email : String, username : String, password_hash : String) : Int64
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO users (email, username, password_hash, created_at) VALUES (?, ?, ?, ?)",
        email, username, password_hash, Time.utc
      )
      db.query_one?("SELECT last_insert_rowid()", as: Int64) || 0i64
    end
  end

  def self.find_user(email_or_username : String)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
         FROM users WHERE email = ? OR username = ? LIMIT 1",
        email_or_username, email_or_username, as: {
          Int32, String, String, String, String?, String?, String?, Time
        }
      )
      
      return nil if result.nil?
      
      id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
      {
        id: id,
        email: email,
        username: username,
        password_hash: password_hash,
        plan: plan || "Free",
        forward_email: forward_email,
        stripe_customer_id: stripe_customer_id,
        created_at: created_at
      }
    end
  end

  def self.find_user_by_id(id : Int32)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
         FROM users WHERE id = ? LIMIT 1",
        id, as: {
          Int32, String, String, String, String?, String?, String?, Time
        }
      )
      
      return nil if result.nil?
      
      id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
      {
        id: id,
        email: email,
        username: username,
        password_hash: password_hash,
        plan: plan || "Free",
        forward_email: forward_email,
        stripe_customer_id: stripe_customer_id,
        created_at: created_at
      }
    end
  end

  def self.find_user_by_email(email : String)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
         FROM users WHERE email = ? LIMIT 1",
        email, as: {
          Int32, String, String, String, String?, String?, String?, Time
        }
      )
      
      return nil if result.nil?
      
      id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
      {
        id: id,
        email: email,
        username: username,
        password_hash: password_hash,
        plan: plan || "Free",
        forward_email: forward_email,
        stripe_customer_id: stripe_customer_id,
        created_at: created_at
      }
    end
  end

  def self.update_user_plan(user_id : Int32, plan : String)
    DB.open(DB_PATH) do |db|
      db.exec("UPDATE users SET plan = ? WHERE id = ?", plan, user_id)
    end
  end

  def self.update_user_forward_email(user_id : Int32, forward_email : String)
    DB.open(DB_PATH) do |db|
      db.exec("UPDATE users SET forward_email = ? WHERE id = ?", forward_email, user_id)
    end
  end

  def self.update_user_stripe_customer_id(user_id : Int32, customer_id : String)
    DB.open(DB_PATH) do |db|
      db.exec("UPDATE users SET stripe_customer_id = ? WHERE id = ?", customer_id, user_id)
    end
  end

  def self.delete_user(user_id : Int32)
    DB.open(DB_PATH) do |db|
      # Delete all related records first
      db.exec("DELETE FROM cloudflare_rules WHERE alias_id IN (SELECT id FROM aliases WHERE user_id = ?)", user_id)
      db.exec("DELETE FROM aliases WHERE user_id = ?", user_id)
      db.exec("DELETE FROM team_members WHERE user_id = ?", user_id)
      db.exec("DELETE FROM domains WHERE owner_id = ?", user_id)
      db.exec("DELETE FROM transactions WHERE user_id = ?", user_id)
      db.exec("DELETE FROM users WHERE id = ?", user_id)
    end
  end

  # Alias methods
  def self.create_alias(user_id : Int32, local_part : String, domain : String, forward_to : String, created_at : Time) : Int64
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO aliases (user_id, local_part, domain, forward_to, created_at) VALUES (?, ?, ?, ?, ?)",
        user_id, local_part, domain, forward_to, created_at
      )
      db.query_one?("SELECT last_insert_rowid()", as: Int64) || 0i64
    end
  end

  def self.get_aliases_by_user(user_id : Int32, active_only : Bool = true) : Array({Int32, String, String, String, Bool, Time})
    DB.open(DB_PATH) do |db|
      query = "SELECT id, local_part, domain, forward_to, active, created_at FROM aliases WHERE user_id = ?"
      query += " AND active = true" if active_only
      
      db.query_all(query, user_id, as: {Int32, String, String, String, Bool, Time})
    end
  end

  def self.get_alias_by_id(alias_id : Int32)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, user_id, local_part, domain, forward_to, active, created_at FROM aliases WHERE id = ?",
        alias_id, as: {Int32, Int32, String, String, String, Bool, Time}
      )
      
      return nil if result.nil?
      
      id, user_id, local_part, domain, forward_to, active, created_at = result
      {
        id: id,
        user_id: user_id,
        local_part: local_part,
        domain: domain,
        forward_to: forward_to,
        active: active,
        created_at: created_at
      }
    end
  end

  def self.get_alias_by_email(local_part : String, domain : String)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, user_id, local_part, domain, forward_to, active, created_at FROM aliases WHERE local_part = ? AND domain = ? AND active = true",
        local_part, domain, as: {Int32, Int32, String, String, String, Bool, Time}
      )
      
      return nil if result.nil?
      
      id, user_id, local_part, domain, forward_to, active, created_at = result
      {
        id: id,
        user_id: user_id,
        local_part: local_part,
        domain: domain,
        forward_to: forward_to,
        active: active,
        created_at: created_at
      }
    end
  end

  def self.deactivate_alias(alias_id : Int32)
    DB.open(DB_PATH) do |db|
      db.exec("UPDATE aliases SET active = false WHERE id = ?", alias_id)
    end
  end

  def self.alias_exists?(local_part : String, domain : String) : Bool
    DB.open(DB_PATH) do |db|
      result = db.query_one?("SELECT 1 FROM aliases WHERE local_part = ? AND domain = ? AND active = true LIMIT 1", local_part, domain, as: Int32)
      !result.nil?
    end
  end

  # Domain methods
  def self.create_domain(domain : String, owner_id : Int32, created_at : Time) : Int64
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO domains (domain, owner_id, created_at) VALUES (?, ?, ?)",
        domain, owner_id, created_at
      )
      db.query_one?("SELECT last_insert_rowid()", as: Int64) || 0i64
    end
  end

  def self.get_domain_by_name(domain : String)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, domain, owner_id, verified, dns_verified_at, created_at FROM domains WHERE domain = ?",
        domain, as: {Int32, String, Int32, Bool, Time?, Time}
      )
      
      return nil if result.nil?
      
      id, domain, owner_id, verified, dns_verified_at, created_at = result
      {
        id: id,
        domain: domain,
        owner_id: owner_id,
        verified: verified,
        dns_verified_at: dns_verified_at,
        created_at: created_at
      }
    end
  end

  def self.get_domains_by_owner(owner_id : Int32) : Array({Int32, String, Bool, Time})
    DB.open(DB_PATH) do |db|
      db.query_all(
        "SELECT id, domain, verified, created_at FROM domains WHERE owner_id = ?",
        owner_id, as: {Int32, String, Bool, Time}
      )
    end
  end

  def self.verify_domain(domain_id : Int32)
    DB.open(DB_PATH) do |db|
      db.exec(
        "UPDATE domains SET verified = true, dns_verified_at = ? WHERE id = ?",
        Time.utc, domain_id
      )
    end
  end

  # Team member methods
  def self.add_team_member(domain_id : Int32, user_id : Int32, invited_by : Int32, role : String = "member", created_at : Time = Time.utc)
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO team_members (domain_id, user_id, role, invited_by, created_at) VALUES (?, ?, ?, ?, ?)",
        domain_id, user_id, role, invited_by, created_at
      )
    end
  end

  def self.get_team_members(domain_id : Int32) : Array({Int32, String, String, Time})
    DB.open(DB_PATH) do |db|
      db.query_all(
        "SELECT tm.user_id, tm.role, u.email, tm.created_at 
         FROM team_members tm
         JOIN users u ON u.id = tm.user_id
         WHERE tm.domain_id = ?",
        domain_id, as: {Int32, String, String, Time}
      )
    end
  end

  def self.is_team_member?(domain_id : Int32, user_id : Int32) : Bool
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT 1 FROM team_members WHERE domain_id = ? AND user_id = ? LIMIT 1",
        domain_id, user_id, as: Int32
      )
      !result.nil?
    end
  end

  def self.remove_team_member(domain_id : Int32, user_id : Int32)
    DB.open(DB_PATH) do |db|
      db.exec("DELETE FROM team_members WHERE domain_id = ? AND user_id = ?", domain_id, user_id)
    end
  end

  # Cloudflare rule methods
  def self.save_cloudflare_rule(alias_id : Int32, rule_id : String, created_at : Time = Time.utc)
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO cloudflare_rules (alias_id, rule_id, created_at) VALUES (?, ?, ?)",
        alias_id, rule_id, created_at
      )
    end
  end

  def self.get_cloudflare_rule_id(alias_id : Int32) : String?
    DB.open(DB_PATH) do |db|
      result = db.query_one?("SELECT rule_id FROM cloudflare_rules WHERE alias_id = ?", alias_id, as: String)
      result
    end
  end

  def self.delete_cloudflare_rule(alias_id : Int32)
    DB.open(DB_PATH) do |db|
      db.exec("DELETE FROM cloudflare_rules WHERE alias_id = ?", alias_id)
    end
  end

  # Transaction methods
  def self.save_transaction(user_id : Int32, reference : String, amount : Int32, plan : String, status : String, created_at : Time = Time.utc)
    DB.open(DB_PATH) do |db|
      db.exec(
        "INSERT INTO transactions (user_id, reference, amount, plan, status, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        user_id, reference, amount, plan, status, created_at
      )
    end
  end

  def self.update_transaction_status(reference : String, status : String, paid_at : Time? = nil)
    DB.open(DB_PATH) do |db|
      if paid_at
        db.exec("UPDATE transactions SET status = ?, paid_at = ? WHERE reference = ?", status, paid_at, reference)
      else
        db.exec("UPDATE transactions SET status = ? WHERE reference = ?", status, reference)
      end
    end
  end

  def self.get_transaction(reference : String)
    DB.open(DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, user_id, reference, amount, plan, status, paid_at, created_at FROM transactions WHERE reference = ?",
        reference, as: {Int32, Int32, String, Int32, String, String, Time?, Time}
      )
      
      return nil if result.nil?
      
      id, user_id, reference, amount, plan, status, paid_at, created_at = result
      {
        id: id,
        user_id: user_id,
        reference: reference,
        amount: amount,
        plan: plan,
        status: status,
        paid_at: paid_at,
        created_at: created_at
      }
    end
  end
end

# Run setup when file loads
DAB.setup