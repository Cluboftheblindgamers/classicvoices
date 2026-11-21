import Foundation
@testable import ClassicPortTest

@main struct ProviderStress {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return info.phys_footprint
    }
    static func main() {
        var settings=SpeechSettings(), profile=PantheraSettings()
        profile.acceptCommands=true; profile.resetCommands=false // bypass cache for every request
        settings.macinTalk["snowleopard"]=profile
        let key="mt106/Alex", provider=MacinTalkProvider()
        let job=SpeechJob.from(ssml:"<speak>Window.</speak>",voiceKey:key,settings:settings)
        var buffer=[Float](repeating:0,count:4096), readings:[UInt64]=[]
        for i in 1...1000 {
            autoreleasepool {
                provider.submit(job,voiceKey:key,settings:settings)
                var complete=false, frames=0
                let end=DispatchTime.now().uptimeNanoseconds + 10_000_000_000
                while !complete && DispatchTime.now().uptimeNanoseconds < end {
                    let result=buffer.withUnsafeMutableBufferPointer {provider.read(into:$0.baseAddress!,count:$0.count)}
                    frames+=result.frames;complete=result.complete
                }
                precondition(complete && frames>0 && provider.metrics.error.isEmpty)
            }
            if i % 200 == 0 { let memory=footprint();readings.append(memory);print("STRESS \(i): \(memory) bytes");fflush(stdout) }
        }
        let growth=Int64(readings.last!)-Int64(readings[0])
        precondition(growth<12*1024*1024,"repeated speech grows beyond bounded warm memory")
        print("PASS 1000 uncached utterances; post-warm footprint growth \(growth) bytes")
    }
}
