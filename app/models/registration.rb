class Registration
    include Mongoid::Document
    include Mongoid::Timestamps
    field :paid, type: Boolean
    field :status
    field :player_strength
    field :signup_timestamp, type: DateTime
    field :payment_timestamps, type: Hash, default: {}
    field :pair, type: Hash
    field :gender
    field :availability, type: Hash
    field :team_style_pref, type: Hash
    field :self_rank, type: Float
    field :commish_rank, type: Float
    field :g_rank, type: Float

    field :acceptance_expires_at, type: DateTime
    field :warning_email_sent_at, type: DateTime  

    field :waiver_acceptance_date, type: DateTime
    field :user_data, type: Hash
    field :notes
    field :comped, type: Boolean
    field :price, type: Float, default: ->{ league.try :price }

    field :payment_id

    field :pair_id, type: Moped::BSON::ObjectId

    validates :commish_rank, :numericality => { integer_only: false, greater_than: 0, less_than: 10, allow_blank: true }
    validate :has_valid_attendance_value, :has_valid_self_rank, :has_valid_primary_role, :has_signed_waiver

    belongs_to :user
    belongs_to :league
    belongs_to :g_rank_result
    belongs_to :pair, class_name: "User"
    has_many :payment_transactions

    before_save :ensure_price
    after_save  :bust_league_cache

    scope :active, where(status: 'active')
    scope :accepted, where(status: 'accepted')
    scope :pending, where(status: 'pending')
    scope :canceled, where(status: 'canceled')
    scope :waitlisted, where(status: 'waitlisted')

    scope :male, where(gender: 'male')
    scope :female, where(gender: 'female')

    def gen_availability
        availability['general'] if availability
    end

    def eos_availability
        availability['attend_tourney_eos'] if availability
    end

    def ensure_price
        self.price = league.price unless self.price.present?
    end

    # Pairing Stuff:

    def old_pair
        if self[:pair]
            self[:pair]['text']
        end
    end

    def linked?
        self.pair_id.present? || cored?
    end

    def cored?
        RegistrationGroup.where(league: self.league, member_ids: self[:user_id]).first.present?
    end

    def accept(expires_at = nil)
        self.status                = 'accepted'
        self.warning_email_sent_at = nil
        self.acceptance_expires_at = expires_at

        if self.save
            RegistrationMailer.delay.registration_accepted(self._id.to_s)
        end
    end

    def activate!
        self.status = 'active'
        save!
        RegistrationMailer.delay.registration_active(self._id.to_s)
    end

    def can_cancel?
        return false if ['active', 'canceled'].include?(status)
        return false if new_record?
        true
    end

    def cancel
        return false if self.status == 'active'

        self.status = 'canceled'
        self.save
    end

    def refund!
        return false unless status == 'active'
        return false if comped

        pt = payment_transactions.first

        result = Braintree::Transaction.refund(pt.transaction_id)


        unless result.success?
            raise result.errors.first.message
        end

        pt.refunded_amount = pt.amount
        pt.save

        self.status = 'canceled'
        save!
    end

    def rank
        self.commish_rank || self.g_rank || self.self_rank
    end

    def core_rank
        return nil unless self.rank
        return nil unless self.league.core_options.type

        constant = self.league.core_options["#{self.gender}_rank_constant"] || 0.0
        coefficient = self.league.core_options["#{self.gender}_rank_coefficient"] || 1.0

        (coefficient*self.rank)+constant
    end

    def waiver_accepted
        !waiver_acceptance_date.nil?
    end

    # Validators
    def has_valid_attendance_value
        unless ['25%', '50%', '75%', '100%'].include?(gen_availability)
            errors.add(:gen_availability, "Please select an attendance percentage.")
        end
    end

    def has_valid_self_rank
        return unless league.allow_self_rank?

        max_rank = 9
        max_rank = 6 if league.sport == 'goaltimate' && user.gender == 'female'

        unless (1..max_rank).include?(self_rank)
            errors.add(:self_rank, "Please select a rank between 1 and #{max_rank}")
        end
    end

    def has_valid_primary_role
        unless ['Runner', 'Thrower', 'Both'].include?(player_strength)
            errors.add(:player_strength, "Please select a primary role.")
        end        
    end

    def has_signed_waiver
        if waiver_acceptance_date.nil?
            errors.add(:waiver_accepted, "You must accept the liability waiver and refund policy to register.")
        end
    end

    private

    def bust_league_cache
        self.league.touch
    end
end
