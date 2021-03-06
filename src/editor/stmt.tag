// Statement

import I from 'Block.Bridge'

import Mixin from './mixin.js'

<statement class='card list-item'>
  <bind-stmt data={data}/>
  <script>
    this.mixin(Mixin.Data)
  </script>
</statement>


<bind-stmt>
  <div class='sig'>
    <bind-var data={var}/>
    <span class='token'>::</span>
    <scheme data={var.value1}/>
  </div>
  <bind each={data, i in data.value0} data={data} renew={renewB(i)}/>

  <script>
    this.mixin(Mixin.Data)
    this.var = I.bindStmtVar(this.data)
    this.renewB = i => d => {
        this.renew(I.renewBindStmt(i)(d)(this.data))
    }
  </script>
</bind-stmt>
