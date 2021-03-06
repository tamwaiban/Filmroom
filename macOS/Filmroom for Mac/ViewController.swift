//
//  ViewController.swift
//  Filmroom for Mac
//
//  Created by 周建明 on 2017/8/11.
//  Copyright © 2017年 周建明. All rights reserved.
//

import Cocoa
import CoreFoundation
import CoreImage
import Metal
import MetalKit


class ViewController: NSViewController, MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
    
    // Implement MTKView draw()
    // Reference to WWDC 2015 Session 510
    func draw(in view: MTKView) {
        var commandBuffer = commandQueue.makeCommandBuffer()
        
        if let currentDrawable = view.currentDrawable{
            
            // the local pointer to baseCIImage
            var inputImage: CIImage!
            
            // baseCIImage may be nil
            if let base = baseCIImage{
                inputImage = base
            }else{
                // if nil, load from sourceTexture
                inputImage = CIImage(mtlTexture: sourceTexture)!
            }
            
            // set input first
            gammaFilter.inputImage = inputImage
            
            // Execute complex filter or not
            if complexOperation{
                metalview.isPaused = true
                /// A Metal library
                var computationLibrary: MTLLibrary!
                
                // Load library file
                do{
                    try computationLibrary = device.makeLibrary(filepath: "ComputeKernel.metallib")
                }catch{
                    fatalError("Load library error")
                }
                
                if SelectBox.indexOfSelectedItem == 0 {
                    // redirect input
                    gaussianFiler.inputImage = inputImage
                    gaussianFiler.sigma = 15
                    
                    /**
                     For fix the unstable condition with processing high pixel pictures
                     */
                    let cgimage = context.createCGImage(gaussianFiler.outputImage, from: inputImage.extent)
                    baseCIImage = CIImage(cgImage: cgimage!)
                }else if SelectBox.indexOfSelectedItem == 1{
                    
                    // Select library function
                    let reOrderKernel = computationLibrary.makeFunction(name: "reposition")!
                    
                    // Set pipeline of Computation
                    var pipelineState: MTLComputePipelineState!
                    do{
                        pipelineState = try device.makeComputePipelineState(function: reOrderKernel)
                    }catch{
                        fatalError("Set up failed")
                    }
                    
                    /*
                    * Create new texture for store the pixel data,
                    * or say any data that requires to be processed by the FFT function
                    */
                    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                    var reorderedTexture: MTLTexture!
                    reorderedTexture = self.device.makeTexture(descriptor: textureDescriptor)
                    
                    /*
                    * Preserve for Argument Buffer
                    */
                    
                    // Pass width and length data to GPU
                    let width = UInt(self.sourceTexture.width)
                    let length = width * UInt(self.sourceTexture.height)

                    
                    /* Figure out the:
                     
                     * The number of threads that are scheduled to execute the same instruction
                     in a compute function at a time.
                     * The largest number of threads that can be in one threadgroup.
                     
                     */
                    let tw = pipelineState.threadExecutionWidth
                    let th = pipelineState.maxTotalThreadsPerThreadgroup / tw
                    
                    let threadPerGroup = MTLSizeMake(tw, th, 1)
                    let threadGroups: MTLSize = MTLSizeMake(Int(self.sourceTexture.width) / threadPerGroup.width, Int(self.sourceTexture.height) / threadPerGroup.height, 1)
                    // config the group number and group size
                    var commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                    let argumentEncoder = reOrderKernel.makeArgumentEncoder(bufferIndex: 0)
                    let encodedLengthBuffer = device.makeBuffer(length:argumentEncoder.encodedLength, options: MTLResourceOptions(rawValue: 0))
                    
                    // Set argument buffer and texture in kernel function
                    commandEncoder?.setComputePipelineState(pipelineState)
                    commandEncoder?.setTexture(reorderedTexture, index: 0)
                    commandEncoder?.setBuffer(encodedLengthBuffer, offset: 0, index: 0)
                    argumentEncoder.setArgumentBuffer(encodedLengthBuffer!, offset: 0)
                    argumentEncoder.setTexture(self.sourceTexture, index: 2)
                    
                    argumentEncoder.constantData(at: 3).storeBytes(of: width, toByteOffset: 0, as: UInt.self)
                    argumentEncoder.constantData(at: 1).storeBytes(of: length, toByteOffset: 0, as: UInt.self)

                    // Config the thread setting
                    commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                    commandEncoder?.endEncoding()
                    
                    // Push the configuration and assignments to GPU
                    commandBuffer?.commit()
                    commandBuffer?.waitUntilCompleted()
                    // Above, finished the re-arrangment
                    

                    // Load function of FFT calculation
                    let fftStageKernel = computationLibrary.makeFunction(name: "fft_allStage")!
                    // Set pipeline of Computation
                    do{
                        pipelineState = try device.makeComputePipelineState(function: fftStageKernel)
                    }catch{
                        fatalError("Set up failed")
                    }

                    // to Int8?
                    let FFT: Int32 = 1
                    let complexConjugate: Int32 = 1
                    let maxStage = Int(log2(Float(length)))
                    // Set texture in kernel
                    // log2 only accept float or double
                    for index in 1...maxStage{
                
                        // Start steps of FFT -- Calculate each row
                        // Refresh the command buffer and encoder for each stage
                        commandBuffer = commandQueue.makeCommandBuffer()
                        commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                        
                        
                        commandEncoder?.setComputePipelineState(pipelineState)
                        commandEncoder?.setTexture(reorderedTexture, index: 0)
                        
                        // Adjust the FFT and complexConjugate to get inverse or complex conjugate
                        let argumentEncoder = fftStageKernel.makeArgumentEncoder(bufferIndex: 0)
                        
                        let encodedLengthBuffer = device.makeBuffer(length:argumentEncoder.encodedLength, options: MTLResourceOptions(rawValue: 0))
                        
                        // Set argument buffer and texture in kernel function
                        commandEncoder?.setBuffer(encodedLengthBuffer, offset: 0, index: 0)
                        argumentEncoder.setArgumentBuffer(encodedLengthBuffer!, offset: 0)
                        argumentEncoder.constantData(at: 1).storeBytes(of: uint2(UInt32(width), UInt32(index)), toByteOffset: 0, as: uint2.self)
                        argumentEncoder.constantData(at: 2).storeBytes(of: int2(FFT, complexConjugate), toByteOffset: 0, as: int2.self)
                        
                        
                        
                        commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                        commandEncoder?.endEncoding()
                        
                        // Push the assignment
                        commandBuffer?.commit()
                    }
                    
                    // Load function of FFT calculation
                    let modulusKernel = computationLibrary.makeFunction(name: "complexModulus")
                    // Set pipeline of Computation
                    do{
                        pipelineState = try device.makeComputePipelineState(function: modulusKernel!)
                    }catch{
                        fatalError("Set up failed")
                    }
                    
                    
                    let resultDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                    var resultTexture: MTLTexture!
                    resultTexture = self.device.makeTexture(descriptor: resultDescriptor)
                    
                    commandBuffer = commandQueue.makeCommandBuffer()
                    commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                    
                    commandEncoder?.setComputePipelineState(pipelineState)
                    
                    commandEncoder?.setTexture(reorderedTexture, index: 0)
                    commandEncoder?.setTexture(resultTexture, index: 1)
                    
                    commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                    commandEncoder?.endEncoding()
                    
                    // Push the assignment
                    commandBuffer?.commit()
                    commandBuffer?.waitUntilCompleted()
                    
                    
                    // Renew the command buffer, and redirect the FFT data to display.
                    commandBuffer = commandQueue.makeCommandBuffer()
                    self.baseCIImage = CIImage(mtlTexture: resultTexture)
                }else if SelectBox.indexOfSelectedItem == 2{
                    
                    /* Comparing the performance between
                     * FFT & DFT
                     * Actually, DFT will become zombie zzzz
                     */
                    
                    // Select library function
                    let dftKernel = computationLibrary.makeFunction(name: "dft")!
                    
                    // Set pipeline of Computation
                    var pipelineState: MTLComputePipelineState!
                    do{
                        pipelineState = try device.makeComputePipelineState(function: dftKernel)
                    }catch{
                        fatalError("Set up failed")
                    }
                    
                    /*
                     * Create result texture for store the pixel data
                     */
                    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                    var destiny: MTLTexture!
                    destiny = self.device.makeTexture(descriptor: textureDescriptor)
                    
                    // config the group number and group size
                    let commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                    
                    /* Figure out the:
                     
                     * The number of threads that are scheduled to execute the same instruction
                     in a compute function at a time.
                     * The largest number of threads that can be in one threadgroup.
                     
                     */
                    let tw = pipelineState.threadExecutionWidth
                    let th = pipelineState.maxTotalThreadsPerThreadgroup / tw
                    
                    let threadPerGroup = MTLSizeMake(tw, th, 1)
                    let threadGroups: MTLSize = MTLSizeMake(Int(self.sourceTexture.width) / threadPerGroup.width, Int(self.sourceTexture.height) / threadPerGroup.height, 1)
                    
                    
                    // Set texture in kernel
                    commandEncoder?.setComputePipelineState(pipelineState)
                    commandEncoder?.setTexture(self.sourceTexture, index: 1)
                    commandEncoder?.setTexture(destiny, index: 0)
                    
                    // Pass width and length data to GPU
                    var width = self.sourceTexture.width
                    var length = width * self.sourceTexture.height
                    
                    // Set data buffer
                    let bufferW = device.makeBuffer(bytes: &width, length: MemoryLayout<uint>.stride, options: MTLResourceOptions.storageModeManaged)
                    let bufferL = device.makeBuffer(bytes: &length, length: MemoryLayout<uint>.stride, options: MTLResourceOptions.storageModeManaged)
                    
                    commandEncoder?.setBuffer(bufferW, offset: 0, index: 0)
                    commandEncoder?.setBuffer(bufferL, offset: 0, index: 1)
                    
                    // Config the thread setting
                    commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                    commandEncoder?.endEncoding()
                    
                    // Push the configuration and assignments to GPU
                    commandBuffer?.commit()
                    commandBuffer?.waitUntilCompleted()
                    
                    self.baseCIImage = CIImage(mtlTexture: destiny)
                }else if SelectBox.indexOfSelectedItem == 3{
                    // Select library function
                    let illMapKernel = computationLibrary.makeFunction(name: "illuminationMap")!
                    
                    // Set pipeline of Computation
                    var pipelineState: MTLComputePipelineState!
                    do{
                        pipelineState = try device.makeComputePipelineState(function: illMapKernel)
                    }catch{
                        fatalError("Set up failed")
                    }
                    
                    commandBuffer = commandQueue.makeCommandBuffer()
                    let resultDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                    var resultTexture: MTLTexture!
                    resultTexture = self.device.makeTexture(descriptor: resultDescriptor)
                    
                    let commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                    let tw = pipelineState.threadExecutionWidth
                    let th = pipelineState.maxTotalThreadsPerThreadgroup / tw
                    
                    let threadPerGroup = MTLSizeMake(tw, th, 1)
                    let threadGroups: MTLSize = MTLSizeMake(Int(self.sourceTexture.width) / threadPerGroup.width, Int(self.sourceTexture.height) / threadPerGroup.height, 1)
                    
                    
                    
                    commandEncoder?.setComputePipelineState(pipelineState)
                    commandEncoder?.setTexture(self.sourceTexture, index: 0)
                    commandEncoder?.setTexture(resultTexture, index: 1)
                    
                    var referRadius: UInt = 10
                    commandEncoder?.setBytes(&referRadius, length: MemoryLayout<uint>.stride, index: 0)
                    
                    commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                    commandEncoder?.endEncoding()
                    
                    // Push the assignment
                    commandBuffer?.commit()
                    commandBuffer?.waitUntilCompleted()
                    
                    
                    // Renew the command buffer, and redirect the FFT data to display.
                    commandBuffer = commandQueue.makeCommandBuffer()
                    self.baseCIImage = CIImage(mtlTexture: resultTexture)
                }else if SelectBox.indexOfSelectedItem == 4{
                    // Select library function
                    let graKernel = computationLibrary.makeFunction(name: "gradient")!
                    
                    // Set pipeline of Computation
                    var pipelineState: MTLComputePipelineState!
                    do{
                        pipelineState = try device.makeComputePipelineState(function: graKernel)
                    }catch{
                        fatalError("Set up failed")
                    }
                    
                    commandBuffer = commandQueue.makeCommandBuffer()
                    let resultDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                    var resultTexture: MTLTexture!
                    resultTexture = self.device.makeTexture(descriptor: resultDescriptor)
                    
                    let commandEncoder = commandBuffer?.makeComputeCommandEncoder()
                    let tw = pipelineState.threadExecutionWidth
                    let th = pipelineState.maxTotalThreadsPerThreadgroup / tw
                    
                    let threadPerGroup = MTLSizeMake(tw, th, 1)
                    let threadGroups: MTLSize = MTLSizeMake(Int(self.sourceTexture.width) / threadPerGroup.width, Int(self.sourceTexture.height) / threadPerGroup.height, 1)
                    
                    
                    commandEncoder?.setComputePipelineState(pipelineState)
                    
                    commandEncoder?.setTexture(self.sourceTexture, index: 0)
                    commandEncoder?.setTexture(resultTexture, index: 1)
                    
                    commandEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadPerGroup)
                    commandEncoder?.endEncoding()
                    
                    // Push the assignment
                    commandBuffer?.commit()
                    commandBuffer?.waitUntilCompleted()
                    
                    // Renew the command buffer, and redirect the FFT data to display.
                    commandBuffer = commandQueue.makeCommandBuffer()
                    self.baseCIImage = CIImage(mtlTexture: resultTexture)
                }

                gammaFilter.inputImage = baseCIImage
                complexOperation = false
                metalview.isPaused = false
                
            }
            
            
            gammaFilter.inputUnit = CGFloat(GammaSlider.floatValue)
            
            context.render(gammaFilter.outputImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: inputImage.extent, colorSpace: colorSpace!)
            commandBuffer?.present(currentDrawable)
            commandBuffer?.commit()
        }
        
    }
    
    /**
     * Reference to https://denbeke.be/blog/programming/swift-open-file-dialog-with-nsopenpanel/
     */
    @IBAction func OpenFile(sender: AnyObject) {
        
        let dialog = NSOpenPanel();
        
        dialog.title                   = "Choose a photo file";
        dialog.showsResizeIndicator    = true;
        dialog.showsHiddenFiles        = false;
        dialog.canChooseDirectories    = false;
        dialog.canCreateDirectories    = true;
        dialog.allowsMultipleSelection = false;
        dialog.allowedFileTypes        = ["jpg", "jpeg", "png", "NEF", "CD2", "tif"];
        
        if (dialog.runModal() == NSApplication.ModalResponse.OK) {
            let result = dialog.url // Pathname of the file
            
            if (result != nil) {
                let path = result!.path
                let textureLoader = MTKTextureLoader(device: device)
                
                do {
                    try sourceTexture = textureLoader.newTexture(URL: URL(fileURLWithPath: path), options: [MTKTextureLoader.Option.origin: MTKTextureLoader.Origin.bottomLeft])
                    
                    
                    metalview.setFrameSize(sourceTexture.aspectRadio.FrameSize)
                    metalview.drawableSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
                    
                    baseCIImage = nil
                } catch  {
                    print("fail to read")
                }
                
                
            }
        } else {
            // User clicked on "Cancel"
            return
        }
        
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    @IBOutlet var GammaSlider: NSSlider!
    @IBOutlet var SigmaSlider: NSSlider!
    @IBOutlet weak var SelectBox: NSComboBoxCell!
    
    
    //var ciimage: CIImage?
    
    let gammaFilter = GammaAdjust()
    let gaussianFiler = GuassianBlur()
    
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var sourceTexture: MTLTexture!
    
    // Used among the whole controller
    var metalview: MTKView!
    
    // Core Image resources
    var context: CIContext!
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
    var textureLoader: MTKTextureLoader!
    var complexOperation = false
    
    // Variable for light-weight filter input
    //(very first input of that kind filter chain))
    var baseCIImage: CIImage?
    
    override func loadView() {
        super.loadView()
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device.makeCommandQueue()
        
        textureLoader = MTKTextureLoader(device: device)
        
        // Load the start image
        do {
            try sourceTexture = textureLoader.newTexture(name: "Welcome", scaleFactor: 2.0, bundle: Bundle.main, options: [MTKTextureLoader.Option.origin: MTKTextureLoader.Origin.bottomLeft])
            
        } catch  {
            print("fail to read")
        }
        
//        sourceTexture.makeTextureView(pixelFormat: .bgra8Unorm)
        
        // Set up MTKView
        metalview = MTKView(frame: CGRect(x: 30, y: 50, width: 600, height: 400), device: self.device)
        metalview.setFrameSize(sourceTexture.aspectRadio.FrameSize)
        metalview.delegate = self
        metalview.framebufferOnly = false
        // Save the depth drawable to lower memory increasing
        metalview.sampleCount = 1
        metalview.depthStencilPixelFormat = .invalid
        metalview.preferredFramesPerSecond = 3
        
        // Set the correct draw size
        metalview.drawableSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
        view.addSubview(metalview)
        
        // Link the cicontext
        context = CIContext(mtlDevice: device)
        
        
        gammaFilter.setDefaults()
    }
    
    @IBAction func SavePhoto(_ sender: NSButton) {
        
        let resultImage = metalview.currentDrawable?.texture.toNSImage
        resultImage?.writeJPG(toURL: URL(fileURLWithPath: "/Users/jerrychou/output.jpg"))
        //metalview.releaseDrawables()
    }
    

    @IBAction func SaveImage(_ sender: NSButton) {

        let resultImage = metalview.currentDrawable?.texture.toNSImage
        let dialog = NSSavePanel()

        dialog.title                   = "Save image to"
        dialog.showsResizeIndicator    = true
        dialog.showsHiddenFiles        = false
        dialog.canCreateDirectories    = true
        dialog.allowedFileTypes        = ["jpg"]


        if (dialog.runModal() == NSApplication.ModalResponse.OK) {
            let result = dialog.url // Pathname of the file

            if (result != nil) {
                let path = result!.path

                resultImage?.writeJPG(toURL: URL(fileURLWithPath: path))
            }
        } else {
            // User clicked on "Cancel"
            return
        }
    }
    
    @IBAction func ComplexProcess(_ sender: NSButton) {
        complexOperation = true
    }
    
    @IBAction func PauseRendering(_ sender: NSButton) {
        if metalview.isPaused {
            metalview.isPaused = false
        }else{
            metalview.isPaused = true
        }
    }
}

