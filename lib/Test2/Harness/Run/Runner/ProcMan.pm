package Test2::Harness::Run::Runner::ProcMan;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use List::Util qw/first/;
use Time::HiRes qw/sleep/;

use File::Spec();

use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Run::Runner::ProcMan::Locker();
use Test2::Harness::Util::File::JSONL();
use Test2::Harness::Run::Queue();

our $VERSION = '0.001042';

use Test2::Harness::Util::HashBase qw{
    -pid
    -queue  -queue_ended
    -jobs   -jobs_file -jobs_seen
    -stages

    -locker
    -pending
    -_pids
    -end_loop_cb

    -dir
    -run
    -wait_time
};

my %CATEGORIES = (
    long       => 1,
    medium     => 1,
    general    => 1,
    isolation  => 1,
    immiscible => 1,
);

sub init {
    my $self = shift;

    croak "'run' is a required attribute"
        unless $self->{+RUN};

    croak "'dir' is a required attribute"
        unless $self->{+DIR};

    croak "'queue' is a required attribute"
        unless $self->{+QUEUE};

    croak "'jobs_file' is a required attribute"
        unless $self->{+JOBS_FILE};

    croak "'stages' is a required attribute"
        unless $self->{+STAGES};

    $self->{+PID} = $$;

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+JOBS} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});
    $self->{+JOBS_SEEN} = {};

    $self->{+LOCKER} = Test2::Harness::Run::Runner::ProcMan::Locker->new(
        dir => $self->{+DIR},
        slots => $self->{+RUN}->job_count,
    );

    $self->read_jobs();
    $self->preload_queue();
}

sub read_jobs {
    my $self = shift;

    my $jobs = $self->{+JOBS};
    return unless $jobs->exists;

    my $jobs_seen = $self->{+JOBS_SEEN};
    for my $job ($jobs->read) {
        $jobs_seen->{$job->{job_id}}++;
    }
}

sub preload_queue {
    my $self = shift;

    my $run = $self->{+RUN};

    return $self->poll_tasks unless $run->finite;

    my $wait_time = $self->{+WAIT_TIME};
    until ($self->{+QUEUE_ENDED}) {
        $self->poll_tasks() and next;
        sleep($wait_time) if $wait_time;
    }

    return 1;
}

sub poll_tasks {
    my $self = shift;

    return if $self->{+QUEUE_ENDED};

    my $queue = $self->{+QUEUE};
    if ($self->{+PID} != $$) {
        $queue->reset;
        $self->{+PID} = $$;
    }

    my $added = 0;
    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        next if $task && $self->{+JOBS_SEEN}->{$task->{job_id}}++;

        $added++;

        if (!$task) {
            $self->{+QUEUE_ENDED} = 1;
            last;
        }

        my $cat = $task->{category};
        $cat = 'general' unless $cat && $CATEGORIES{$cat};
        $task->{category} = $cat;

        my $stage = $task->{stage};
        $stage = 'default' unless $stage && $self->{+STAGES}->{$stage};
        $task->{stage} = $stage;

        push @{$self->{+PENDING}->{$stage}} => $task;
    }

    return $added;
}

sub job_started {
    my $self   = shift;
    my %params = @_;

    my $pid = $params{pid};
    my $job = $params{job};

    $self->{+_PIDS}->{$pid} = \%params;

    $self->{+JOBS}->write({%{$job->TO_JSON}, pid => $pid});
}

# Children of this process should be killed
sub kill {
    my $self = shift;
    my ($sig) = @_;
    $sig = 'TERM' unless defined $sig;

    for my $pid (keys %{$self->{+_PIDS}}) {
        kill($sig, $pid) or warn "Could not kill pid";
    }

    return;
}

# This process is going to exit, do any final waiting
sub finish {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};
    while (keys %{$self->{+_PIDS}}) {
        $self->wait_on_jobs and next;
        sleep($wait_time) if $wait_time;
    }

    return;
}

sub wait_on_jobs {
    my $self = shift;
    my %params = @_;

    for my $pid (keys %{$self->{+_PIDS}}) {
        my $check = waitpid($pid, WNOHANG);
        my $exit = $?;

        next unless $check || $params{force_exit};

        my $params = delete $self->{+_PIDS}->{$pid};
        my $cat = $params->{task}->{category};

        unless ($check == $pid) {
            $exit = -1;
            warn "Waitpid returned $check for pid $pid" if $check;
        }

        $self->write_exit(%$params, exit => $exit);
    }
}

sub write_remaining_exits {
    my $self = shift;
    $self->wait_on_jobs(force_exit => 1);
}

sub write_exit {
    my $self = shift;
    my %params = @_;
    my $file = File::Spec->catfile($params{dir}, 'exit');
    write_file_atomic($file, $params{exit});
}

sub next {
    my $self = shift;
    my ($stage) = @_;

    my $list      = $self->{+PENDING}->{$stage} ||= [];
    my $wait_time = $self->{+WAIT_TIME};
    my $end_cb    = $self->{+END_LOOP_CB};
    my $locker    = $self->{+LOCKER};

    my $no_gen = 0;
    while (@$list || !$self->{+QUEUE_ENDED}) {
        return if $end_cb && $end_cb->();

        my $gen = 0;
        $no_gen = 0 if $self->poll_tasks;
        $self->wait_on_jobs;

        unless (@$list) {
            sleep($wait_time) if $wait_time;
            next;
        }

        # If the first item is an isolation then it is time, we have to run it,
        # so block until we own all slots.
        my $cat = $list->[0]->{category};
        if ($cat eq 'isolation') {
            my $task = shift @$list;
            my $lock = $locker->get_isolation(block => 1);
            return ($task, $lock);
        }

        # Get a lock, everything from here on out needs one.
        my $lock = $locker->get_lock();
        unless($lock) {
            sleep($wait_time) if $wait_time;
            next;
        }

        my (%seen, $use, $fallback);
        for (my $i = 0; $i < @$list; $i++) {
            my $task = $list->[$i];
            my $cat = $task->{category};
            next if $cat eq 'isolation'; # Not handled here.

            if ($cat eq 'general') {
                $use = $i;
                last;
            }
            else {
                $fallback = $i unless defined $fallback;
                next if $seen{$cat}++;

                my $meth = "get_$cat";
                my $add_lock = $locker->$meth or next;
                $lock->merge($add_lock);
                $use = $i;
                last;
            }
        }

        $use = $fallback unless defined $use;
        if (defined $use) {
            my $task = splice(@$list, $use, 1);
            return ($task, $lock);
        }

        sleep($wait_time) if $wait_time;
    }

    return;
}

1;
