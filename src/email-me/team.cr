require "json"
require "./db"

class Team
  property id : Int32
  property domain : String
  property owner_id : Int32
  property verified : Bool

  def initialize(@id : Int32, @domain : String, @owner_id : Int32, @verified : Bool)
  end

  # Domain Management
  def self.add_domain(domain : String, owner_id : Int32) : Tuple(Bool, String | Int32)
    unless domain.match(/^[a-z0-9.-]+\.[a-z]{2,}$/i)
      return {false, "Invalid domain format"}
    end

    existing = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM domains WHERE domain = $1 LIMIT 1",
      domain, as: Int32
    )

    if existing
      return {false, "Domain already added"}
    end

    EmailMe::DB.connection.exec(
      "INSERT INTO domains (domain, owner_id, verified, created_at)
       VALUES ($1, $2, $3, $4)",
      domain, owner_id, false, Time.utc
    )

    domain_id = EmailMe::DB.connection.query_one(
      "SELECT currval('domains_id_seq')",
      as: Int32
    )

    {true, domain_id}
  end

  def self.get_user_domains(user_id : Int32) : Array(DomainInfo)
    owned = EmailMe::DB.connection.query_all(
      "SELECT id, domain, owner_id, verified FROM domains WHERE owner_id = $1",
      user_id, as: {Int32, String, Int32, Bool}
    )

    member = EmailMe::DB.connection.query_all(
      "SELECT d.id, d.domain, d.owner_id, d.verified
       FROM domains d
       JOIN team_members tm ON tm.domain_id = d.id
       WHERE tm.user_id = $1",
      user_id, as: {Int32, String, Int32, Bool}
    )

    (owned + member).map do |id, domain, owner_id, verified|
      DomainInfo.new(id, domain, owner_id, verified, owner_id == user_id)
    end
  end

  # Team Member Management
  def self.invite_member(domain_id : Int32, inviter_id : Int32, invitee_email : String, role : String = "member") : Tuple(Bool, String)
    unless can_manage_team?(domain_id, inviter_id)
      return {false, "You don't have permission to invite members"}
    end

    invitee = find_user_by_email(invitee_email)
    if invitee.nil?
      return {false, "User with email #{invitee_email} not found"}
    end

    existing = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM team_members WHERE domain_id = $1 AND user_id = $2 LIMIT 1",
      domain_id, invitee[:id], as: Int32
    )

    if existing
      return {false, "User is already a team member"}
    end

    EmailMe::DB.connection.exec(
      "INSERT INTO team_members (domain_id, user_id, role, invited_by, created_at)
       VALUES ($1, $2, $3, $4, $5)",
      domain_id, invitee[:id], role, inviter_id, Time.utc
    )

    {true, "Invited #{invitee_email}"}
  end

  def self.remove_member(domain_id : Int32, requester_id : Int32, member_id : Int32) : Tuple(Bool, String)
    unless can_manage_team?(domain_id, requester_id)
      return {false, "You don't have permission to remove members"}
    end

    member = EmailMe::DB.connection.query_one?(
      "SELECT user_id FROM team_members WHERE domain_id = $1 AND user_id = $2",
      domain_id, member_id, as: Int32
    )

    if member.nil?
      return {false, "Member not found"}
    end

    owner = EmailMe::DB.connection.query_one?(
      "SELECT owner_id FROM domains WHERE id = $1",
      domain_id, as: Int32
    )

    if owner == member_id
      return {false, "Cannot remove domain owner"}
    end

    EmailMe::DB.connection.exec(
      "DELETE FROM team_members WHERE domain_id = $1 AND user_id = $2",
      domain_id, member_id
    )

    {true, "Member removed"}
  end

  def self.get_team_members(domain_id : Int32, requester_id : Int32) : Array(TeamMember)
    unless is_team_member?(domain_id, requester_id)
      return [] of TeamMember
    end

    results = EmailMe::DB.connection.query_all(
      "SELECT tm.user_id, tm.role, tm.created_at, u.email, u.username
       FROM team_members tm
       JOIN users u ON u.id = tm.user_id
       WHERE tm.domain_id = $1",
      domain_id, as: {Int32, String, Time, String, String}
    )

    owner = EmailMe::DB.connection.query_one?(
      "SELECT u.id, u.email, u.username
       FROM domains d
       JOIN users u ON u.id = d.owner_id
       WHERE d.id = $1",
      domain_id, as: {Int32, String, String}
    )

    members = [] of TeamMember

    if owner
      owner_id, owner_email, owner_username = owner
      members << TeamMember.new(
        user_id: owner_id,
        email: owner_email,
        username: owner_username,
        role: "owner",
        created_at: Time.utc
      )
    end

    results.each do |user_id, role, created_at, email, username|
      members << TeamMember.new(
        user_id: user_id,
        email: email,
        username: username,
        role: role,
        created_at: created_at
      )
    end

    members
  end

  # Permission Checks
  def self.can_manage_team?(domain_id : Int32, user_id : Int32) : Bool
    owner = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM domains WHERE id = $1 AND owner_id = $2 LIMIT 1",
      domain_id, user_id, as: Int32
    )

    return true if owner

    admin = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM team_members WHERE domain_id = $1 AND user_id = $2 AND role = 'admin' LIMIT 1",
      domain_id, user_id, as: Int32
    )

    !admin.nil?
  end

  def self.is_team_member?(domain_id : Int32, user_id : Int32) : Bool
    owner = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM domains WHERE id = $1 AND owner_id = $2 LIMIT 1",
      domain_id, user_id, as: Int32
    )

    return true if owner

    member = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM team_members WHERE domain_id = $1 AND user_id = $2 LIMIT 1",
      domain_id, user_id, as: Int32
    )

    !member.nil?
  end

  def self.can_create_alias?(user_id : Int32, domain : String) : Bool
    domain_info = EmailMe::DB.connection.query_one?(
      "SELECT id, owner_id FROM domains WHERE domain = $1",
      domain, as: {Int32, Int32}
    )

    return false if domain_info.nil?

    domain_id, owner_id = domain_info

    return true if owner_id == user_id

    member = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM team_members WHERE domain_id = $1 AND user_id = $2 LIMIT 1",
      domain_id, user_id, as: Int32
    )

    !member.nil?
  end

  # Helper to find user by email (replaces DAB.find_user_by_email)
  private def self.find_user_by_email(email : String) : NamedTuple(id: Int32, email: String, username: String)?
    result = EmailMe::DB.connection.query_one?(
      "SELECT id, email, username FROM users WHERE email = $1 LIMIT 1",
      email, as: {Int32, String, String}
    )

    return nil if result.nil?

    id, email, username = result
    {id: id, email: email, username: username}
  end
end

# Data structures
struct DomainInfo
  property id : Int32
  property domain : String
  property owner_id : Int32
  property verified : Bool
  property is_owner : Bool

  def initialize(@id : Int32, @domain : String, @owner_id : Int32, @verified : Bool, @is_owner : Bool)
  end
end

struct TeamMember
  property user_id : Int32
  property email : String
  property username : String
  property role : String
  property created_at : Time

  def initialize(@user_id : Int32, @email : String, @username : String, @role : String, @created_at : Time)
  end
end
