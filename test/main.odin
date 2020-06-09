package main

import ".."
import "core:time"
import "core:fmt"

print_file :: proc(event: heimdall.Event)
{
     fmt.printf("%s: %v\n", event.filename, event.flags);
}

main :: proc()
{
     watcher := heimdall.init_watcher();
     heimdall.watch_file(&watcher, "./foo", {.Delete}, print_file);
     heimdall.watch_file(&watcher, "./foo", {.Create}, print_file);
     for
         {
         time.sleep(time.Second);
         heimdall.poll_events(&watcher);
     }
}