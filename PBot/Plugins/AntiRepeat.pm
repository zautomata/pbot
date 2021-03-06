# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::Plugins::AntiRepeat;

use warnings;
use strict;

use feature 'switch';
no if $] >= 5.018, warnings => "experimental::smartmatch";

use Carp ();

use String::LCSS qw/lcss/;
use Time::HiRes qw/gettimeofday/;
use POSIX qw/strftime/;

sub new {
  Carp::croak("Options to " . __FILE__ . " should be key/value pairs, not hash reference") if ref $_[1] eq 'HASH';
  my ($class, %conf) = @_;
  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  $self->{pbot} = delete $conf{pbot} // Carp::croak("Missing pbot reference to " . __FILE__);

  $self->{pbot}->{registry}->add_default('text', 'antiflood', 'antirepeat',           $conf{antirepeat}           // 1);
  $self->{pbot}->{registry}->add_default('text', 'antiflood', 'antirepeat_threshold', $conf{antirepeat_threshold} // 2.5);
  $self->{pbot}->{registry}->add_default('text', 'antiflood', 'antirepeat_match',     $conf{antirepeat_match}     // 0.5);
  $self->{pbot}->{registry}->add_default('text', 'antiflood', 'antirepeat_allow_bot', $conf{antirepeat_allow_bot} // 1);

  $self->{pbot}->{event_dispatcher}->register_handler('irc.public', sub { $self->on_public(@_) });

  $self->{pbot}->{timer}->register(sub { $self->adjust_offenses }, 60 * 60 * 1, 'antirepeat');

  $self->{offenses} = {};
}

sub unload {
  my $self = shift;
  # perform plugin clean-up here
  # normally we'd unregister the 'irc.public' event handler; however, the
  # event dispatcher will do this automatically for us when it sees there
  # is no longer an existing sub.

  $self->{pbot}->{timer}->unregister('antirepeat');
}

sub on_public {
  my ($self, $event_type, $event) = @_;
  my ($nick, $user, $host, $msg) = ($event->{event}->nick, $event->{event}->user, $event->{event}->host, $event->{event}->args);
  my $channel = $event->{event}->{to}[0];

  ($nick, $user, $host) = $self->{pbot}->{irchandlers}->normalize_hostmask($nick, $user, $host);

  return 0 if not $self->{pbot}->{registry}->get_value('antiflood', 'antirepeat');

  my $antirepeat = $self->{pbot}->{registry}->get_value($channel, 'antirepeat');
  return 0 if defined $antirepeat and not $antirepeat;
  
  return 0 if $channel !~ m/^#/;
  return 0 if $event->{interpreted};
  return 0 if $self->{pbot}->{antiflood}->whitelisted($channel, "$nick!$user\@$host", 'antiflood');

  my $account = $self->{pbot}->{messagehistory}->{database}->get_message_account($nick, $user, $host);
  my $messages = $self->{pbot}->{messagehistory}->{database}->get_recent_messages($account, $channel, 6, $self->{pbot}->{messagehistory}->{MSG_CHAT});

  my $botnick = $self->{pbot}->{registry}->get_value('irc', 'botnick');

  my $bot_trigger = $self->{pbot}->{registry}->get_value($channel, 'trigger')
    // $self->{pbot}->{registry}->get_value('general', 'trigger');

  my $allow_bot = $self->{pbot}->{registry}->get_value($channel, 'antirepeat_allow_bot')
    // $self->{pbot}->{registry}->get_value('antiflood', 'antirepeat_allow_bot');

  my $match = $self->{pbot}->{registry}->get_value($channel, 'antirepeat_match')
    // $self->{pbot}->{registry}->get_value('antiflood', 'antirepeat_match');

  my %matches;
  my $now = gettimeofday;

  foreach my $string1 (@$messages) {
    next if $now - $string1->{timestamp} > 60 * 60 * 2;
    next if $allow_bot and $string1->{msg} =~ m/^(?:$bot_trigger|$botnick.?)/;

    if (exists $self->{offenses}->{$account} and exists $self->{offenses}->{$account}->{$channel}) {
      next if $self->{offenses}->{$account}->{$channel}->{last_offense} >= $string1->{timestamp};
    }

    foreach my $string2 (@$messages) {
      next if $now - $string2->{timestamp} > 60 * 60 * 2;
      next if $allow_bot and $string2->{msg} =~ m/^(?:$bot_trigger|$botnick.?)/;

      if (exists $self->{offenses}->{$account} and exists $self->{offenses}->{$account}->{$channel}) {
        next if $self->{offenses}->{$account}->{$channel}->{last_offense} >= $string2->{timestamp};
      }

      my $string = lcss(lc $string1->{msg}, lc $string2->{msg});

      if (defined $string) {
        my $length = length $string;
        my $length1 = $length / length $string1->{msg};
        my $length2 = $length / length $string2->{msg};

        if ($length1 >= $match && $length2 >= $match) {
          $matches{$string}++;
        }
      }
    }
  }

  my $threshold = $self->{pbot}->{registry}->get_value($channel, 'antirepeat_threshold')
    // $self->{pbot}->{registry}->get_value('antiflood', 'antirepeat_threshold');

  foreach my $match (keys %matches) {
    if (sqrt $matches{$match} > $threshold) {
      $self->{offenses}->{$account}->{$channel}->{last_offense} = gettimeofday;
      $self->{offenses}->{$account}->{$channel}->{last_adjustment} = gettimeofday;
      $self->{offenses}->{$account}->{$channel}->{offenses}++;

      given ($self->{offenses}->{$account}->{$channel}->{offenses}) {
        when (1) {
          $self->{pbot}->{chanops}->add_op_command($channel, "kick $channel $nick Stop repeating yourself");
          $self->{pbot}->{chanops}->gain_ops($channel);
        }
        when (2) {
          $self->{pbot}->{chanops}->ban_user_timed("*!*\@$host", $channel, 60);
        }
        when (3) {
          $self->{pbot}->{chanops}->ban_user_timed("*!*\@$host", $channel, 60 * 15);
        }
        default {
          $self->{pbot}->{chanops}->ban_user_timed("*!*\@$host", $channel, 60 * 60);
        }
      }
      return 0;
    }
  }

  return 0;
}

sub adjust_offenses {
  my $self = shift;
  my $now = gettimeofday;

  foreach my $account (keys %{ $self->{offenses} }) {
    foreach my $channel (keys %{ $self->{offenses}->{$account} }) {
      if ($self->{offenses}->{$account}->{$channel}->{offenses} > 0 and $now - $self->{offenses}->{$account}->{$channel}->{last_adjustment} > 60 * 60 * 3) {
        $self->{offenses}->{$account}->{$channel}->{offenses}--;

        if ($self->{offenses}->{$account}->{$channel}->{offenses} <= 0) {
          delete $self->{offenses}->{$account}->{$channel};
          if (keys %{ $self->{offenses}->{$account} } == 0) {
            delete $self->{offenses}->{$account};
          }
        } else {
          $self->{offenses}->{$account}->{$channel}->{last_adjustment} = $now;
        }
      }
    }
  }
}

1;
