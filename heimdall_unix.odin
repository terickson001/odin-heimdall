package heimdall

import "core:sys/unix"
import "core:fmt"
import "core:os"
import "shared:inotify"
import "path"

@private
to_inotify_mask :: proc(mask: Event_Mask) -> (out_mask: inotify.Event_Mask)
{
     if .Create in mask do out_mask |= {.Create};
     if .Delete in mask do out_mask |= {.Delete};
     if .Access in mask do out_mask |= {.Access};
     if .Modify in mask do out_mask |= {.Modify};
     if .Close  in mask do out_mask |= {.Close_Write, .Close_NoWrite};
     if .Open   in mask do out_mask |= {.Open};
     if .Move   in mask do out_mask |= {.Moved_From, .Moved_To};
     
     return out_mask;
}

@private
from_inotify_mask :: proc(mask: inotify.Event_Mask) -> (out_mask: Event_Mask)
{
     if .Create in mask do out_mask |= {.Create};
     if .Delete in mask do out_mask |= {.Delete};
     if .Access in mask do out_mask |= {.Access};
     if .Modify in mask do out_mask |= {.Modify};
     if transmute(u32)(mask & {.Close_Write, .Close_NoWrite}) != 0 do out_mask |= {.Close};
     if .Open in mask do out_mask |= {.Open};
     if transmute(u32)(mask & {.Moved_From, .Moved_To}) != 0 do out_mask |= {.Move};
     
     return out_mask;
}

init_watcher :: proc(allocator := context.allocator) -> Watcher
{
     watcher := Watcher{};
     watcher.handle = inotify.init();
     watcher.foci = make(T=type_of(watcher.foci), allocator=allocator);
     watcher.unhandled_events = make([dynamic]Event, allocator);
     watcher.allocator = allocator;
     return watcher;
}

watch_directory :: proc(watcher: ^Watcher, filepath: string, mask: Event_Mask, handler : Directory_Event_Proc = nil)
{
     focus := Focus{};
     focus.directory = filepath;
     focus.mask = mask;
     focus.variant = Directory_Focus{handler=handler};
     
     err: os.Errno;
     focus.handle, err = inotify.add_watch(watcher.handle, focus.directory, to_inotify_mask(mask));
     
     if focus.handle not_in watcher.foci
         {
         watcher.foci[focus.handle] = make([dynamic]Focus, watcher.allocator);
     }
     append(&watcher.foci[focus.handle], focus);
}

watch_file :: proc(watcher: ^Watcher, filepath: string, mask: Event_Mask, handler : File_Event_Proc = nil)
{
     focus := Focus{};
     focus.directory = path.dir(filepath);
     focus.mask = mask;
     focus.variant = File_Focus{filename=path.base(filepath), handler=handler};
     
     err: os.Errno;
     focus.handle, err = inotify.add_watch(watcher.handle, focus.directory, to_inotify_mask(mask) | {.Mask_Add});
     
     if focus.handle not_in watcher.foci
         {
         watcher.foci[focus.handle] = make([dynamic]Focus, watcher.allocator);
     }
     append(&watcher.foci[focus.handle], focus);
}

poll_events :: proc(watcher: ^Watcher)
{
     poll_fds := [1]os.Poll_Fd{};
     poll_fds[0].fd = watcher.handle;
     poll_fds[0].events |= {.In};
     if ok, err := os.poll(poll_fds[:]); !ok do
         return;
     
     if .In in poll_fds[0].revents
         {
         inotify_events := inotify.read_events(fd=watcher.handle, allocator=watcher.allocator);
         for in_event in inotify_events
             {
             foci, ok := watcher.foci[in_event.wd];
             if !ok do
                 continue;
             
             event := Event{};
             for focus in foci
                 {
                 in_mask := from_inotify_mask(transmute(inotify.Event_Mask)in_event.mask);
                 if transmute(u8)(focus.mask & in_mask) == 0 do
                     continue;
                 switch v in focus.variant
                     {
                     case File_Focus:
                     if in_event.name != v.filename do
                         continue;
                     event.flags = in_mask;
                     event.focus = focus;
                     event.filename = in_event.name;
                     if v.handler != nil
                         {
                         v.handler(event);
                         continue;
                     }
                     
                     case Directory_Focus:
                     event.flags = in_mask;
                     event.focus = focus;
                     event.filename = in_event.name;
                     if v.handler != nil
                         {
                         v.handler(event);
                         continue;
                     }
                 }
                 append(&watcher.unhandled_events, event);
             }
         }
         
     }
}