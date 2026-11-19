# ---------------------------------------------------------------------------
# See the NOTICE file distributed with this work for additional
# information regarding copyright ownership.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.
# ---------------------------------------------------------------------------
# What the thread dumps of a JVM say, for the summary of a report:
#
#   awk -f threads.awk dump-1.txt dump-2.txt ...
#
# The dumps are those HotSpot writes on SIGQUIT, in the order they were taken, as the journal
# gives them: without empty lines. Works with mawk and gawk.
#
# A thread name is not trusted: XWiki puts the URL of the request in it, which a remote user
# chooses. A name is printed without control characters, and cut.

# clean(text, max): the text on one line, without control characters, cut to max characters.
function clean(text, max) {
  gsub(/[[:cntrl:]]/, " ", text)
  if (length(text) > max) {
    text = substr(text, 1, max) "..."
  }
  return text
}

# field(text, name, unit): the number of name=<number><unit> in the text, or -1.
function field(text, name, unit,    re) {
  re = name "=[0-9.]+" unit
  if (!match(text, re)) {
    return -1
  }
  return substr(text, RSTART + length(name) + 1, RLENGTH - length(name) - 1 - length(unit)) + 0
}

FNR == 1 {
  dump++
  tail = 0
  current = ""
  in_deadlock = 0
  after_heap = 0
}

# The end of the threads: what follows is about the whole JVM.
/^JNI global refs/ {
  tail = 1
  current = ""
}

# "name" #12 [345] daemon prio=5 os_prio=0 cpu=1.23ms elapsed=4.56s tid=0x... nid=345 runnable
# "VM Thread" os_prio=0 cpu=1.23ms elapsed=4.56s tid=0x... nid=160 runnable
!tail && /^".*" (#[0-9]+ |os_prio=)/ {
  match($0, /" (#[0-9]+ |os_prio=)/)
  name = substr($0, 2, RSTART - 2)
  rest = substr($0, RSTART + 2)
  threads[dump]++
  # The thread of the system, which stays the same from a dump to the next.
  current = ""
  if (match(rest, /nid=[0-9a-fx]+/)) {
    current = substr(rest, RSTART + 4, RLENGTH - 4)
  } else if (match(rest, /tid=0x[0-9a-f]+/)) {
    current = substr(rest, RSTART, RLENGTH)
  }
  if (current != "") {
    cpu = field(rest, "cpu", "ms")
    if (cpu >= 0) {
      if (!(current in first_cpu)) {
        first_cpu[current] = cpu
        first_elapsed[current] = field(rest, "elapsed", "s")
        first_dump[current] = dump
      }
      last_cpu[current] = cpu
      last_elapsed[current] = field(rest, "elapsed", "s")
      last_dump[current] = dump
    }
    thread_name[current] = name
    thread_state[current] = ""
    thread_frame[current] = ""
  }
  # A thread that serves a request: "http-nio-8080-exec-1 - http://host/xwiki/bin/view/Main/".
  if (match(name, / - https?:\/\//)) {
    url = substr(name, RSTART + 3)
    sub(/^https?:\/\/[^\/?#;]*/, "", url)
    sub(/[?#;].*$/, "", url)
    if (url == "") {
      url = "/"
    }
    url = clean(url, 200)
    if (!(url in url_total)) {
      urls++
      url_at[urls] = url
    }
    url_total[url]++
    url_count[url, dump]++
  }
  next
}

!tail && /^ +java\.lang\.Thread\.State: / {
  state = clean($2, 30)
  states[dump, state]++
  if (current != "") {
    thread_state[current] = state
  }
  next
}

!tail && current != "" && thread_frame[current] == "" && /^[ \t]+at / {
  frame = $0
  sub(/^[ \t]+at /, "", frame)
  thread_frame[current] = frame
  next
}

# Found one Java-level deadlock: who waits for whom, up to the stacks.
tail && /^Found (one|[0-9]+) Java-level deadlock/ {
  in_deadlock = 1
  deadlock_dump = dump
  deadlock = ""
}
tail && /^Java stack information/ {
  in_deadlock = 0
}
in_deadlock {
  if ($0 !~ /^=+$/) {
    deadlock = deadlock "  " clean($0, 300) "\n"
  }
  next
}

tail && after_heap {
  heap[dump] = clean($0, 200)
  sub(/^ +/, "", heap[dump])
  after_heap = 0
}
tail && /^Heap$/ {
  after_heap = 1
}

END {
  if (dump == 0) {
    exit 0
  }
  line = ""
  for (d = 1; d <= dump; d++) {
    line = line (d > 1 ? ", " : "") threads[d] + 0
  }
  printf "Thread dumps: %d (threads in each: %s)\n", dump, line

  line = ""
  count = split("RUNNABLE BLOCKED WAITING TIMED_WAITING NEW TERMINATED", order, " ")
  for (i = 1; i <= count; i++) {
    if ((dump, order[i]) in states) {
      line = line (line == "" ? "" : ", ") order[i] " " states[dump, order[i]]
    }
  }
  if (line != "") {
    printf "Java threads by state, in the last dump: %s\n", line
  }
  if (dump in heap) {
    printf "Heap, in the last dump: %s\n", heap[dump]
  }

  if (deadlock != "") {
    printf "\nDeadlock, in dump %d:\n%s", deadlock_dump, deadlock
  } else {
    printf "No deadlock.\n"
  }

  if (urls > 0) {
    printf "\nRequests being served, by URL: the threads on each one, in each dump.\n"
    for (shown = 0; shown < 10 && shown < urls; shown++) {
      best = 0
      for (i = 1; i <= urls; i++) {
        if (!(i in url_done) && (best == 0 || url_total[url_at[i]] > url_total[url_at[best]])) {
          best = i
        }
      }
      url_done[best] = 1
      line = ""
      for (d = 1; d <= dump; d++) {
        line = line sprintf("%5d", url_count[url_at[best], d] + 0)
      }
      printf "%s  %s\n", line, url_at[best]
    }
    if (urls > 10) {
      printf "  and %d other URLs\n", urls - 10
    }
  } else {
    printf "\nNo thread is serving a request.\n"
  }

  # The threads seen in two dumps or more, by the CPU time they used between them.
  candidates = 0
  for (key in first_cpu) {
    if (last_dump[key] > first_dump[key] && last_cpu[key] - first_cpu[key] >= 1) {
      candidates++
      used[key] = last_cpu[key] - first_cpu[key]
    }
  }
  if (dump < 2) {
    printf "\nOne dump only: it does not tell which threads use the CPU.\n"
  } else if (candidates == 0) {
    printf "\nNo thread used the CPU between the dumps.\n"
  } else {
    printf "\nThreads that used the most CPU between two dumps:\n"
    for (shown = 0; shown < 10 && shown < candidates; shown++) {
      best = ""
      for (key in used) {
        if (best == "" || used[key] > used[best]) {
          best = key
        }
      }
      seconds = last_elapsed[best] - first_elapsed[best]
      name = thread_name[best]
      sub(/[?].*$/, "", name)
      line = sprintf("%7d ms", used[best])
      if (seconds > 0) {
        line = line sprintf(" in %2d s", seconds + 0.5)
      }
      line = line "  " clean(name, 200)
      if (thread_state[best] != "") {
        line = line "  [" thread_state[best] "]"
      }
      if (thread_frame[best] != "") {
        line = line "  " clean(thread_frame[best], 200)
      }
      print line
      delete used[best]
    }
  }
}
