---------------------------------------------------------------
--  Activity-Recognition-with-CNN-and-RNN
--  https://github.com/chihyaoma/Activity-Recognition-with-CNN-and-RNN
-- 
-- 
--  Contact: Chih-Yao Ma at <cyma@gatech.edu>
---------------------------------------------------------------

--
--  Copyright (c) 2016, Facebook, Inc.
--  All rights reserved.
--
--  This source code is licensed under the BSD-style license found in the
--  LICENSE file in the root directory of this source tree. An additional grant
--  of patent rights can be found in the PATENTS file in the same directory.
--
--  Generic model creating code. For the specific ResNet model see
--  models/resnet.lua
--

require 'nn'
require 'cunn'
require 'cudnn'

local M = {}

function M.setup(opt, checkpoint)
   local model
   if checkpoint then
      local modelPath = paths.concat(opt.resume, checkpoint.modelFile)
      assert(paths.filep(modelPath), 'Saved model not found: ' .. modelPath)
      print('=> Resuming model from ' .. modelPath)
      model = torch.load(modelPath)
   elseif opt.retrain ~= 'none' then
      assert(paths.filep(opt.retrain), 'File not found: ' .. opt.retrain)
      print('Loading model from file: ' .. opt.retrain)
      model = torch.load(opt.retrain)

      if opt.dataset == 'ucf101-flow' then

         print('fine-tuning the temporal network from file: ' .. opt.retrain)
         local inputChannel = opt.nChannel
         if opt.nStacking ~= 'false' then
            inputChannel = opt.nChannel * opt.nStacking
         end

         -- duplicate the first spatial convolution layer to the # of stacking frames
         local layerDim = model:get(1).weight:size()
         local old_weight = model:get(1).weight
         -- average the channels in the first layer
         local avgWeight = torch.mean(old_weight, 2)

         -- replace the first spatial convolution layer
         model:remove(1)
         model:insert(cudnn.SpatialConvolution(
            inputChannel,layerDim[1],layerDim[3],layerDim[4],2,2,3,3),1)

         -- change the number of layers to the # of input channel, and expand
         layerDim[2] = inputChannel
         avgWeight = torch.expand(avgWeight, layerDim)

         -- update with the new weight
         model:get(1).weight = avgWeight:float()

      elseif opt.dataset == 'ucf101' then
         print('fine-tuning the spatial network from file: ' .. opt.retrain)
      end
      
      -- replace the spatial pooling layer, if downsample the image is required
      if opt.downsample ~='false' then
         assert(torch.type(model:get(#model.modules-2)) == 'cudnn.SpatialAveragePooling',
          'unknown network structure, please use ResNet')
         model:remove(#model.modules-2)
         model:insert(cudnn.SpatialAveragePooling(4, 4, 1, 1), #model.modules-1)
      end

      -- convert back to cuda
      model:cuda()

   else
      print('=> Creating model from file: models/' .. opt.netType .. '.lua')
      model = require('models/' .. opt.netType)(opt)
   end

   print(model)
   -- First remove any DataParallelTable
   if torch.type(model) == 'nn.DataParallelTable' then
      model = model:get(1)
   end

   -- This is useful for fitting ResNet-50 on 4 GPUs, but requires that all
   -- containers override backwards to call backwards recursively on submodules
   if opt.shareGradInput then
      local function sharingKey(m)
         local key = torch.type(m)
         if m.__shareGradInputKey then
            key = key .. ':' .. m.__shareGradInputKey
         end
         return key
      end

      -- Share gradInput for memory efficient backprop
      local cache = {}
      model:apply(function(m)
         local moduleType = torch.type(m)
         if torch.isTensor(m.gradInput) and moduleType ~= 'nn.ConcatTable' then
            local key = sharingKey(m)
            if cache[key] == nil then
               cache[key] = torch.CudaStorage(1)
            end
            m.gradInput = torch.CudaTensor(cache[key], 1, 0)
         end
      end)
      for i, m in ipairs(model:findModules('nn.ConcatTable')) do
         if cache[i % 2] == nil then
            cache[i % 2] = torch.CudaStorage(1)
         end
         m.gradInput = torch.CudaTensor(cache[i % 2], 1, 0)
      end
   end

   -- For resetting the classifier when fine-tuning on a different Dataset
   if opt.resetClassifier and not checkpoint then
      print(' => Replacing classifier with ' .. opt.nClasses .. '-way classifier')

      local orig = model:get(#model.modules)
      assert(torch.type(orig) == 'nn.Linear',
         'expected last layer to be fully connected')

      local linear = nn.Linear(orig.weight:size(2), opt.nClasses)
      linear.bias:zero()

      model:remove(#model.modules)
      model:add(linear:cuda())
   end

   -- Set the CUDNN flags
   if opt.cudnn == 'fastest' then
      cudnn.fastest = true
      cudnn.benchmark = true
   elseif opt.cudnn == 'deterministic' then
      -- Use a deterministic convolution implementation
      model:apply(function(m)
         if m.setMode then m:setMode(1, 1, 1) end
      end)
   end

   -- Wrap the model with DataParallelTable, if using more than one GPU
   if opt.nGPU > 1 then
      local gpus = torch.range(1, opt.nGPU):totable()
      local fastest, benchmark = cudnn.fastest, cudnn.benchmark

      local dpt = nn.DataParallelTable(1, true, true)
         :add(model, gpus)
         :threads(function()
            local cudnn = require 'cudnn'
            cudnn.fastest, cudnn.benchmark = fastest, benchmark
         end)
      dpt.gradInput = nil

      model = dpt:cuda()
   end

   local criterion = nn.CrossEntropyCriterion():cuda()
   return model, criterion
end

return M